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

interface IMsgSender {
    function msgSender() external view returns (address);
}

contract BatchingHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for int256;

    error OnlySelf();

    // cached batch transaction
    struct SwapTransaction {
        int256 amountSpecified;
        bool zeroForOne;
        address receiver;
    }

    // cached batch state
    struct BatchState {
        uint256 amountToken0;
        uint256 amountToken1;
        uint160 upperSqrtClearingPriceX96;
        uint160 lowerSqrtClearingPriceX96;
        SwapTransaction[] transactions;
    }

    uint16 constant BATCH_FREQUENCY = 2;

    // transaction cache
    mapping(PoolId => BatchState) public batchStates;

    // trusted routers
    mapping(address swapRouter => bool approved) public verifiedRouters;

    bool allowSwap;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        allowSwap = false;
    }

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

    function addRouter(address _router) external {
        verifiedRouters[_router] = true;
    }

    function removeRouter(address _router) external {
        verifiedRouters[_router] = false;
    }

    function getHookData(address user) public pure returns (bytes memory) {
        return abi.encode(user);
    }

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

    function _beforeSwap(
        address sender, 
        PoolKey calldata key, 
        SwapParams calldata params, 
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];
        if (allowSwap) {
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

            //TODO: make sure sender is a trusted router
            address user;
            try IMsgSender(sender).msgSender() returns (address swapper) {
                user = swapper;
            } catch {
                revert("Router does not implement msgSender()");
            }

            // take the input token so that v3-swap is skipped
            uint256 amountTaken = uint256(-params.amountSpecified);
            Currency input = params.zeroForOne ? key.currency0 : key.currency1;
            poolManager.mint(address(this), input.toId(), amountTaken);


            // update the batch state with the new transaction
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

    function _resolveSwapDelta(BalanceDelta delta, PoolKey memory key) internal {
        _resolveCurrencyDelta(key.currency0, BalanceDeltaLibrary.amount0(delta));
        _resolveCurrencyDelta(key.currency1, BalanceDeltaLibrary.amount1(delta));
    }

    function _resolveCurrencyDelta(Currency currency, int128 delta) private {
        if (delta < 0) {
            poolManager.burn(address(this), currency.toId(), uint256(-int256(delta)));
        } else if (delta > 0) {
            poolManager.mint(address(this), currency.toId(), uint256(uint128(delta)));
        }
    }

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

    function _burnClaimAndTake(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
    }

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

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
            _revertBatch(batchState.transactions, pk);
            delete batchStates[poolId];
            bytes memory rtnData = abi.encode(false);
            return rtnData;
        }
    }

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