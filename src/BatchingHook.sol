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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/**
 * @title BatchingHook
 * @author luket3
 * @notice creates a beforeSwap hook that captures trades 
 *         before swap and then executes as a batch
 */
contract BatchingHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for int256;

    /// @notice thrown when a function is called from a non-hook context
    error OnlySelf();

    /// @notice thrown if the balancing swap exceeds the price limit
    error PriceLimitHit();

    /// @notice thrown when hook calldata is malformed
    error InvalidHookData();

    /// @notice thrown when clearBatch is called before MIN_BATCH_SIZE transactions have arrived
    error BatchTooSmall();

    /// @notice minimum number of queued swaps required before clearBatch can settle
    uint256 constant MIN_BATCH_SIZE = 5;

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
        uint160 sqrtStartPriceX96;
        uint160 upperSqrtClearingPriceX96;
        uint160 lowerSqrtClearingPriceX96;
        SwapTransaction[] transactions;
    }

    /// @notice batch state keyed by pool id for queued swaps awaiting settlement
    mapping(PoolId => BatchState) public batchStates;

    /// @dev guards the settlement swap from re-entering the batch logic during execution
    //      only used for testing will be removed in final product
    bool allowSwap;

    /// @dev the ID of the batch currently collecting, increases sequentially
    uint256 currBatchId;

    /// @notice creates the batching hook bound to a pool manager
    /// @param _poolManager the Uniswap v4 pool manager instance
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        allowSwap = false;
        currBatchId = 0;
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
        PoolKey calldata pk,
        BatchState storage batchState, 
        bool zeroForOne,
        uint160 sqrtPriceLimitX96
    ) internal returns (bool) {
        if (batchState.transactions.length == 0) {
            batchState.upperSqrtClearingPriceX96 = TickMath.MAX_SQRT_PRICE;
            batchState.lowerSqrtClearingPriceX96 = TickMath.MIN_SQRT_PRICE;
            (batchState.sqrtStartPriceX96,,,) = poolManager.getSlot0(pk.toId());
        }

        // 0 means "no limit": nothing to tighten
        if (sqrtPriceLimitX96 == 0) return true;

        if (zeroForOne) {
            // limit is a price floor
            if (sqrtPriceLimitX96 > batchState.sqrtStartPriceX96) return false;
            if (sqrtPriceLimitX96 > batchState.lowerSqrtClearingPriceX96) {
                batchState.lowerSqrtClearingPriceX96 = sqrtPriceLimitX96;
            }
        } else {
            // limit is a price ceiling
            if (sqrtPriceLimitX96 < batchState.sqrtStartPriceX96) return false;
            if (sqrtPriceLimitX96 < batchState.upperSqrtClearingPriceX96) {
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
                    key,
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
            SwapTransaction storage swapTransaction = transactions[i];
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
        SwapTransaction[] storage transactions,
        PoolKey memory key
    ) internal {
        for (uint256 i = 0; i < transactions.length; i++) {
            SwapTransaction storage swapTransaction = transactions[i];
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
        try poolManager.take(currency, recipient, amount) {}
        catch {}
    }

    /// @notice tries to swap some amount, if the swap trades past the provided
    ///         price limit reverts the swap
    /// @param key the pool key of the pool to swap too
    /// @param zeroForOne if the trade is swapping token0 for token1
    /// @param amountIn the amount to swap
    /// @param sqrtPriceLimitX96 the price limit of the swap
    /// @return delta the BalanceDelta returned by the swap
    function swapOrRevert(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (BalanceDelta delta) {
        if (msg.sender != address(this)) revert OnlySelf();

        int256 amountSpecified = -int256(amountIn);
        allowSwap = true;
        delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );
        allowSwap = false;

        int128 inputSide = zeroForOne ? delta.amount0() : delta.amount1();
        if (inputSide != amountSpecified) revert PriceLimitHit(); // undoes the swap
    }

    /// @notice Given amounts of token0 and token1, find how much of the
	///         "excess" token to remove so the remainders are worth exactly
	///         the same at `sqrtPriceX96` (value1 = value0 * price).
	/// @param amount0 amount of token0
	/// @param amount1 amount of token1
	/// @param sqrtPriceX96 the price to trade tokens at
	/// @return excessIsToken0 true if token0 is the excess side
	/// @return excessAmount   amount of the excess token to remove (the residual)
	function netAtPrice(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96)
		internal
		pure
		returns (bool excessIsToken0, uint256 excessAmount)
	{
		// value of all token0 expressed in token1: amount0 * (sqrtP / 2^96)^2
		// (two mulDivs because sqrtP^2 can exceed 256 bits)
		uint256 value0In1 = FullMath.mulDiv(
			FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
		);

		if (value0In1 > amount1) {
			// token0 is in excess: keep only as much token0 as amount1 can match
			// keep0 = amount1 / price = amount1 * 2^192 / sqrtP^2 (rounded down)
			uint256 keep0 = FullMath.mulDiv(
				FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
			);
			if (keep0 > amount0) keep0 = amount0; // guard against rounding
			excessIsToken0 = true;
			excessAmount = amount0 - keep0;
		} else {
			// token1 is in excess: keep only as much token1 as amount0 is worth
			uint256 keep1 = value0In1; // already rounded down
			excessIsToken0 = false;
			excessAmount = amount1 - keep1;
		}
	}

    /// @notice pays the batch-clearing caller a gas rebate split equally in value
    ///         across both token reserves held by the hook.
    /// @dev    called after any residual pool swap so the full reserve is available;
    ///         each side is capped at the hook's current claim balance to prevent underflow.
    /// @param pk the pool key whose reserves fund the rebate
    /// @param caller the address that called clearBatch and will receive the rebate
    /// @param batchState the batch being settled, used for n and the entry sqrtPrice
    function _payCompensation(
        PoolKey memory pk,
        address caller,
        BatchState storage batchState
    ) internal {
        uint256 n = batchState.transactions.length;
        // gas price is capped at 2× basefee to prevent fee-spike manipulation
        uint256 effectiveGasPrice = tx.gasprice < 2 * block.basefee ? tx.gasprice : 2 * block.basefee;
        // half of (221700 + 40600n) * effectiveGasPrice * 1.1, one half per token side
        uint256 halfEth = (221700 + 40600 * n) * effectiveGasPrice * 11 / 20;

        // convert the ETH-denominated half to an equivalent token1 amount at the
        // batch entry price:  c1 = halfEth * (sqrtP / 2^96)^2
        uint256 c1 = FullMath.mulDiv(
            FullMath.mulDiv(halfEth, batchState.sqrtStartPriceX96, FixedPoint96.Q96),
            batchState.sqrtStartPriceX96,
            FixedPoint96.Q96
        );

        uint256 bal0 = poolManager.balanceOf(address(this), pk.currency0.toId());
        uint256 bal1 = poolManager.balanceOf(address(this), pk.currency1.toId());
        uint256 comp0 = halfEth < bal0 ? halfEth : bal0;
        uint256 comp1 = c1     < bal1 ? c1      : bal1;

        _burnClaimAndTake(pk.currency0, caller, comp0);
        _burnClaimAndTake(pk.currency1, caller, comp1);
    }

    /// @notice executes the queued batch settlement inside the pool manager unlock callback
    /// @param data encoded pool data and the clearBatch caller needed to settle the batch
    /// @return rtnData a boolean outcome encoded for the caller
    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        // try to calculate balancing trade
        (PoolKey memory pk, address caller) = abi.decode(data, (PoolKey, address));
        PoolId poolId = pk.toId();
        BatchState storage batchState = batchStates[poolId];
        (bool excessIsToken0, uint256 excessAmount) = netAtPrice(
            batchState.amountToken0,
            batchState.amountToken1,
            batchState.sqrtStartPriceX96);

        bool okay;
        if (excessAmount > 0) {
            uint160 sqrtPriceLimitX96 = excessIsToken0
                ? batchState.lowerSqrtClearingPriceX96
                : batchState.upperSqrtClearingPriceX96;
            try this.swapOrRevert(pk, excessIsToken0, excessAmount, sqrtPriceLimitX96) returns (BalanceDelta delta) {
                // if the settlement swap is valid
                _resolveSwapDelta(delta, pk);
                _payCompensation(pk, caller, batchState);
                _clearTransactions(
                    batchState.transactions,
                    batchState.amountToken0,
                    batchState.amountToken1,
                    pk);
                okay = true;
            } catch {
                // if the settlement swap violates sqrtPriceLimit
                _revertBatch(batchState.transactions, pk);
                okay = false;
            }
        } else {
            // if branch is perfectly balanced
            _payCompensation(pk, caller, batchState);
            _clearTransactions(
                    batchState.transactions,
                    batchState.amountToken0,
                    batchState.amountToken1,
                    pk);
            okay = true;
        }
        delete batchStates[poolId];
        bytes memory rtnData = abi.encode(okay);
        return rtnData;
    }

    /// @notice shared settlement path for both clearBatch variants
    function _executeClear(PoolKey calldata key) internal returns (bool) {
        BatchState storage batchState = batchStates[key.toId()];
        if (batchState.transactions.length == 0) return false;
        currBatchId++;
        bytes memory output = poolManager.unlock(abi.encode(key, msg.sender));
        return abi.decode(output, (bool));
    }

    /// @notice settles a queued batch; reverts if fewer than MIN_BATCH_SIZE swaps have arrived
    /// @param key the pool whose pending batch should be processed
    /// @return settled true if the batch executed successfully
    function clearBatch(PoolKey calldata key) external returns (bool) {
        BatchState storage batchState = batchStates[key.toId()];
        if (batchState.transactions.length < MIN_BATCH_SIZE) revert BatchTooSmall();
        return _executeClear(key);
    }

    /// @notice allows the caller to check if batchId is cleared
    /// @param batchId the id of batch to check if cleared
    function cleared(uint batchId) external view returns (bool) {
        return batchId == currBatchId;
    }


    // all functions below are for testing purposes only, will be removed for
    // final product

    /// @notice settles a queued batch immediately, ignoring BATCH_INTERVAL
    /// @param key the pool whose pending batch should be processed
    /// @return settled true if the batch executed successfully
    function clearBatchNoInterval(PoolKey calldata key) external returns (bool) {
        return _executeClear(key);
    }

    function allowRegularSwap() external {
        allowSwap = true;
    }

    function disallowRegularSwap() external {
        allowSwap = false;
    }
}