// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {console} from "forge-std/console.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BalanceCalc} from "./BalanceCalc.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract BatchingHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for int256;

    /// @notice thrown when a function is called from a non-hook context
    error OnlySelf();

    /// @notice thrown when hook calldata is malformed
    error InvalidHookData();

    /// @notice cached transaction data for one queued batch swap
    struct SwapTransaction {
        int256 amountSpecified;
        bool zeroForOne;
        address receiver;
    }

    /// @notice cached pool-level batch state used when settling queued swaps
    struct BatchState {
        uint256 amountToken0;
        uint256 amountToken1;
        uint160 upperSqrtClearingPriceX96;
        uint160 lowerSqrtClearingPriceX96;
        SwapTransaction[] transactions;
    }

    /// @notice batch state keyed by pool id for queued swaps awaiting settlement
    mapping(PoolId => BatchState) public batchStates;

    /// @dev guards the settlement swap from re-entering the batch logic during execution
    bool allowSwap;

    /// @notice creates the batching hook bound to a pool manager
    /// @param _poolManager the Uniswap v4 pool manager instance
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        allowSwap = false;
    }

    /// @notice returns the hook permissions required by the batching logic
    /// @return permissions the permitted hook callbacks for this contract
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice encodes the caller identity into a hook payload for batch processing
    /// @param user the user whose address should be propagated with the swap
    /// @return hookData the encoded user payload
    function getHookData(address user) public pure returns (bytes memory) {
        return abi.encode(user);
    }

    /// @notice validates that the next transaction fits within the current batch price bounds
    /// @dev updates the batches upper and lower price limit if a tighter bound is found
    /// @param batchState the in-flight batch state for the pool
    /// @param zeroForOne the direction of the candidate swap
    /// @param sqrtPriceLimitX96 the price limit being checked for the candidate swap
    /// @return valid true if the transaction can be added to the current batch
    function _checkValidTransaction(
        BatchState storage batchState, 
        bool zeroForOne,
        uint160 sqrtPriceLimitX96
    ) internal returns (bool) {
        if (batchState.transactions.length == 0) {
            batchState.upperSqrtClearingPriceX96 = TickMath.MAX_SQRT_PRICE;
            batchState.lowerSqrtClearingPriceX96 = TickMath.MIN_SQRT_PRICE;
        } 

        if (zeroForOne) {
            if (sqrtPriceLimitX96 > batchState.upperSqrtClearingPriceX96) return false;
            if (sqrtPriceLimitX96 > batchState.lowerSqrtClearingPriceX96) {
                batchState.lowerSqrtClearingPriceX96 = sqrtPriceLimitX96;
            }
        } else {
            if (sqrtPriceLimitX96 < batchState.lowerSqrtClearingPriceX96) return false;
            if (sqrtPriceLimitX96 < batchState.upperSqrtClearingPriceX96 && sqrtPriceLimitX96 != 0) {
                batchState.upperSqrtClearingPriceX96 = sqrtPriceLimitX96;
            }
        }
        return true;
    }

    /// @notice records a queued swap in the pool batch state
    /// @param batchState the active batch state being updated
    /// @param zeroForOne the direction of the queued swap
    /// @param amountTaken the amount taken from the user input token by the hook
    /// @param amountSpecified the exact swap amount specified by the user
    /// @param user the recipient for the final settlement payout
    function _updateBatchState(
        BatchState storage batchState,
        bool zeroForOne,
        uint256 amountTaken,
        int256 amountSpecified,
        address user
    ) internal {
        if (zeroForOne) {
            batchState.amountToken0 += amountTaken;
        } else {
            batchState.amountToken1 += amountTaken;
        }

        batchState.transactions.push(SwapTransaction({
            amountSpecified: amountSpecified,
            zeroForOne: zeroForOne,
            receiver: user
        }));
    }

    /// @notice intercepts swap calls to queue exact-input trades into the batch until settlement
    /// @param key the pool key for the current swap
    /// @param params the parameters of the incoming swap
    /// @param hookData caller metadata passed into the hook
    /// @return selector the hook callback selector
    /// @return delta the before-swap delta applied to the hook-managed balance
    /// @return fee the fee override for the swap, if any
    function _beforeSwap(
        address, 
        PoolKey calldata key, 
        SwapParams calldata params, 
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];
        if (allowSwap) {
        // allows exact input swaps during batch balancing
            if (params.amountSpecified >= 0) revert("settlement swap must be exact-input");
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        } else if (params.amountSpecified < 0) {
        // AsyncSwap only works on exact-input swaps
            if (!_checkValidTransaction(
                    batchState, 
                    params.zeroForOne, 
                    params.sqrtPriceLimitX96)) {
                revert("BatchingHook: Invalid transaction for current batch");
            }

            // take the input token so that v3-swap is skipped
            uint256 amountTaken = uint256(-params.amountSpecified);
            Currency input = params.zeroForOne ? key.currency0 : key.currency1;
            poolManager.mint(address(this), input.toId(), amountTaken);


            // update the batch state with the new transaction
            if (hookData.length != 32) revert InvalidHookData();
            address user = abi.decode(hookData, (address));
            _updateBatchState(
                batchState,
                params.zeroForOne,
                amountTaken,
                params.amountSpecified,
                user
            );

            // return the amount that's taken by the hook
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int256(amountTaken).toInt128(), 0), 0);
        } else {
            revert("only exact-input swaps are supported by the batching hook");
        }

    }

    /// @notice calls the balance calculator from the hook context so it can validate settlement amounts
    /// @param key the pool being balanced
    /// @param amountIn0 the held token0 amount in the batch
    /// @param amountIn1 the held token1 amount in the batch
    /// @param sqrtPriceUpperX96 the upper clearing-price bound for the simulation
    /// @param sqrtPriceLowerX96 the lower clearing-price bound for the simulation
    /// @return amount the required settlement amount in the chosen direction
    /// @return zeroForOne whether the trade should execute zero-for-one
    function _callBalanceCalc(
        PoolKey memory key,
		uint256 amountIn0,
		uint256 amountIn1,
		uint160 sqrtPriceUpperX96,
		uint160 sqrtPriceLowerX96
    ) external view returns (uint256 amount, bool zeroForOne) {
        if (msg.sender != address(this)) revert OnlySelf();
        return BalanceCalc.getAmountToBalance(poolManager, key, amountIn0, amountIn1, sqrtPriceUpperX96, sqrtPriceLowerX96);
    }

    /// @notice attempts to compute the settlement trade for the current batch state
    /// @param key the pool being settled
    /// @param amountIn0 the queued token0 balance for the batch
    /// @param amountIn1 the queued token1 balance for the batch
    /// @param sqrtPriceUpperX96 the upper settlement bound
    /// @param sqrtPriceLowerX96 the lower settlement bound
    /// @return amount the settlement amount to swap
    /// @return zeroForOne the direction of the settlement swap
    /// @return valid true if a valid balancing trade exists
    function _getAmountToBalance(
        PoolKey memory key,
		uint256 amountIn0,
		uint256 amountIn1,
		uint160 sqrtPriceUpperX96,
		uint160 sqrtPriceLowerX96
    ) internal view returns(uint256 amount, bool zeroForOne, bool valid) { 
        try this._callBalanceCalc(key, amountIn0, amountIn1, sqrtPriceUpperX96, sqrtPriceLowerX96)
            returns (uint256 _amount, bool _zeroForOne)
        {
            return (_amount, _zeroForOne, true);
        } catch {
            return (0, false, false);
        }
    }

    /// @notice computes the settlement trade and price limit for the current batch
    /// @param sqrtPriceUpperX96 the upper limit for the settlement trade
    /// @param sqrtPriceLowerX96 the lower limit for the settlement trade
    /// @param amount0 the token0 amount queued in the batch
    /// @param amount1 the token1 amount queued in the batch
    /// @param key the pool undergoing settlement
    /// @return amount the swap amount to execute
    /// @return sqrtPriceLimitX96 the price cap or floor for the settlement swap
    /// @return zeroForOne the direction of the settlement swap
    /// @return valid true if the batch can be settled with a valid balancing trade
    function _calculateSwap(
        uint160 sqrtPriceUpperX96, 
        uint160 sqrtPriceLowerX96,
        uint256 amount0,
        uint256 amount1,
        PoolKey memory key
    ) internal view returns (uint256 amount, uint160 sqrtPriceLimitX96, bool zeroForOne, bool valid) {
        (amount, zeroForOne, valid) = _getAmountToBalance(
            key, amount0, amount1, sqrtPriceUpperX96, sqrtPriceLowerX96
        );

        if (!valid) {
            return (0, 0, false, false);
        }
        sqrtPriceLimitX96 = zeroForOne 
            ? sqrtPriceLowerX96 
            : sqrtPriceUpperX96;
    }

    /// @notice resolves the pool delta back into mint and burn operations for the hook account
    /// @param delta the delta produced by the settlement swap
    /// @param key the pool whose balances are being reconciled
    function _resolveSwapDelta(BalanceDelta delta, PoolKey memory key) internal {
        _resolveCurrencyDelta(key.currency0, BalanceDeltaLibrary.amount0(delta));
        _resolveCurrencyDelta(key.currency1, BalanceDeltaLibrary.amount1(delta));
    }

    /// @notice applies any positive or negative currency delta to the hook-managed balance
    /// @param currency the token being reconciled
    /// @param delta the signed token delta to settle
    function _resolveCurrencyDelta(Currency currency, int128 delta) private {
        if (delta < 0) {
            poolManager.burn(address(this), currency.toId(), uint256(-int256(delta)));
        } else if (delta > 0) {
            poolManager.mint(address(this), currency.toId(), uint256(uint128(delta)));
        }
    }

    /// @notice settles each queued swap by distributing the correct share of the batch output
    /// @param transactions the queued swap list to process
    /// @param amountToken0 the total amount of token0 held in the batch
    /// @param amountToken1 the total amount of token1 held in the batch
    /// @param key the pool whose settlement outputs should be distributed
    function _clearTransactions(
        SwapTransaction[] storage transactions, 
        uint256 amountToken0,
        uint256 amountToken1,
        PoolKey memory key) internal {
        uint256 totalOutput0 = poolManager.balanceOf(address(this), key.currency0.toId());
        uint256 totalOutput1 = poolManager.balanceOf(address(this), key.currency1.toId());

        for (uint256 i = 0; i < transactions.length; i++) {
            SwapTransaction memory swapTransaction = transactions[i];
            uint256 amountIn = uint256(-swapTransaction.amountSpecified);
            uint256 outputAmount;
            if (swapTransaction.zeroForOne) {
                outputAmount = FullMath.mulDiv(amountIn, totalOutput1, amountToken0);
                _burnClaimAndTake(key.currency1, swapTransaction.receiver, outputAmount);
            } else {
                outputAmount = FullMath.mulDiv(amountIn, totalOutput0, amountToken1);
                _burnClaimAndTake(key.currency0, swapTransaction.receiver, outputAmount);
            }
        }
    }

    /// @notice reverts a queued batch by returning each user’s input token to the original receiver
    /// @param transactions the queued swaps that need to be unwound
    /// @param key the pool associated with the pending batch
    function _revertBatch(
        SwapTransaction[] memory transactions,
        PoolKey memory key
    ) internal {
        for (uint256 i = 0; i < transactions.length; i++) {
            SwapTransaction memory swapTransaction = transactions[i];
            uint256 amountIn = uint256(-swapTransaction.amountSpecified);
            Currency input = swapTransaction.zeroForOne ? key.currency0 : key.currency1;
            _burnClaimAndTake(input, swapTransaction.receiver, amountIn);
        }
    }

    /// @notice burns the hook’s held amount and transfers it to the provided recipient
    /// @param currency the token being returned
    /// @param recipient the address receiving the funds
    /// @param amount the amount to take and send
    function _burnClaimAndTake(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
    }

    /// @notice executes the queued batch settlement inside the pool manager unlock callback
    /// @param data encoded pool data needed to settle the batch
    /// @return rtnData a boolean outcome encoded for the caller
    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        // try to calculate balancing trade
        (PoolKey memory pk) = abi.decode(data, (PoolKey));
        PoolId poolId = pk.toId();
        BatchState storage batchState = batchStates[poolId];
        (uint256 _amount, uint160 _sqrtPriceLimitX96, bool _zeroForOne, bool _valid) = _calculateSwap(
            batchState.upperSqrtClearingPriceX96,
            batchState.lowerSqrtClearingPriceX96,
            batchState.amountToken0,
            batchState.amountToken1,
            pk
        );

        if (_valid) {
        // if a valid settlement swap is found settle batch
            allowSwap = true;
            BalanceDelta delta = poolManager.swap(
            pk,
            SwapParams({
                zeroForOne: _zeroForOne,
                amountSpecified: -int256(_amount),
                sqrtPriceLimitX96: _sqrtPriceLimitX96
            }),
            "");
            allowSwap = false;
            _resolveSwapDelta(delta, pk);
            _clearTransactions(
                batchState.transactions,
                batchState.amountToken0,
                batchState.amountToken1,
                pk);
            
            delete batchStates[poolId];
            bytes memory rtnData = abi.encode(true);
            return rtnData;
        } else {
        // if a valid settlement swap was not found revert batch and return input tokens to users
            _revertBatch(batchState.transactions, pk);
            delete batchStates[poolId];
            bytes memory rtnData = abi.encode(false);
            return rtnData;
        }
    }

    /// @notice settles a queued batch for the provided pool if one exists
    /// @dev this should be called by an outside party to clear the batch
    /// @param key the pool whose pending batch should be processed
    /// @return settled true if the batch executed successfully, false if there was no queued batch
    function clearBatch(
        PoolKey calldata key
    ) external returns (bool) {
        BatchState memory batchState = batchStates[key.toId()];
        if (batchState.transactions.length <= 0) {
            return false;
        }

        bytes memory output = poolManager.unlock(abi.encode(key));
        return abi.decode(output, (bool));
    }
}