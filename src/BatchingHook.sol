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
import {SwapSim} from "./SwapSim.sol";
import {SettlementRouter} from "./SettlementRouter.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

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
        uint160 clearingPriceX96;
        uint160 upperSqrtClearingPriceX96;
        uint160 lowerSqrtClearingPriceX96;
        uint256 setRoutStake;
        bool setRoutStakeZeroForOne;
        bool locked;
        SwapTransaction[] transactions;
    }

    uint16 constant BATCH_FREQUENCY = 2;

    // transaction cache
    mapping(PoolId => BatchState) public batchStates;

    // trusted routers
    mapping(address swapRouter => bool approved) public verifiedRouters;

    SettlementRouter public settlementRouter;

    constructor(IPoolManager _poolManager, SettlementRouter _settlementRouter) BaseHook(_poolManager) {
        settlementRouter = _settlementRouter;
    }

    function setSettlementRouter(address _settlementRouter) external {
        settlementRouter = SettlementRouter(_settlementRouter);
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
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
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

    function _isSettlementSwap(bytes calldata hookData) internal view returns (bool) {
        return hookData.length == 32
            && abi.decode(hookData, (address)) == address(settlementRouter);
    }

    function _checkValidTransaction(
        BatchState storage batchState, 
        PoolId poolId,
        bool zeroForOne,
        uint160 sqrtPriceLimitX96
    ) internal returns (bool) {
        if (batchState.transactions.length == 0) {
            (batchState.clearingPriceX96,,,) = poolManager.getSlot0(poolId);
            batchState.upperSqrtClearingPriceX96 = type(uint160).max;
            batchState.lowerSqrtClearingPriceX96 = 0;
        } 

        if (zeroForOne) {
            if (sqrtPriceLimitX96 > batchState.clearingPriceX96) return false;

            if (sqrtPriceLimitX96 > batchState.lowerSqrtClearingPriceX96) {
                batchState.lowerSqrtClearingPriceX96 = sqrtPriceLimitX96;
            }
        } else {
            if (sqrtPriceLimitX96 < batchState.clearingPriceX96) return false;

            if (sqrtPriceLimitX96 < batchState.upperSqrtClearingPriceX96) {
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
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];
        if (batchState.locked) {
            revert("pool is currently not accepting orders");
        } else if (_isSettlementSwap(hookData)) {
            if (params.amountSpecified >= 0) revert("settlement swap must be exact-input");
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        } else if (params.amountSpecified < 0) {
            // AsyncSwap only works on exact-input swaps
            if (!_checkValidTransaction(
                    batchState, 
                    poolId, 
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

    function lockPool(PoolId poolId) external {
        batchStates[poolId].locked = true;
    }

    function unlockPool(PoolId poolId) internal {
        batchStates[poolId].locked = false;
    }

    function _revertBatch(SwapTransaction[] memory transactions, PoolKey memory key) internal {
        for (uint256 i = 0; i < transactions.length; i++) {
            SwapTransaction memory swapTransaction = transactions[i];
            Currency input = swapTransaction.zeroForOne ? key.currency0 : key.currency1;
            poolManager.burn(swapTransaction.receiver, input.toId(), uint256(-swapTransaction.amountSpecified));
        }

    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (SwapTransaction[] memory transactions, PoolKey memory key) = abi.decode(data, (SwapTransaction[], PoolKey));
        _revertBatch(transactions, key);
        return "";
    }

    function revertBatch(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        bytes memory data = abi.encode(batchStates[key.toId()].transactions, key);

        poolManager.unlock(data);
        delete batchStates[key.toId()];
        unlockPool(poolId);
    }

    function _calculateSwap(
        uint160 _sqrtPriceLimitX96, 
        uint256 _amountToken0,
        uint256 _amountToken1
    ) internal pure returns (uint256 amount, bool zeroForOne) {
        uint256 priceX128 = FullMath.mulDiv(
            _sqrtPriceLimitX96,
            _sqrtPriceLimitX96,
            1 << 64
        );
        uint256 amountZeroForOne = FullMath.mulDiv(
            _amountToken0,
            priceX128,
            1 << 128
        );

        // Excess token0
        if (amountZeroForOne > _amountToken1) {
            uint256 numerator = amountZeroForOne - _amountToken1;
            amount = FullMath.mulDiv(
                numerator,
                1 << 127,
                priceX128
            );
            zeroForOne = true;
        // Excess token1
        } else if (amountZeroForOne < _amountToken1) {
            uint256 numerator = _amountToken1 - amountZeroForOne;
            amount = numerator / 2;
            zeroForOne = false;
        // Already exactly at the target price
        } else {
            amount = 0;
            zeroForOne = false;
        }
    }

    function clearTransactions(
        SwapTransaction[] storage transactions, 
        uint256 amountToken0,
        uint256 amountToken1,
        PoolKey calldata key) internal {
        while (transactions.length > 0) {
            SwapTransaction memory swapTransaction = transactions[transactions.length - 1];
            Currency input;
            uint256 outputAmount;
            if (swapTransaction.zeroForOne) {
                input = key.currency1;
                outputAmount = FullMath.mulDiv(
                    uint256(-swapTransaction.amountSpecified),
                    amountToken1,
                    amountToken0
                );
            } else {
                input = key.currency0;
                outputAmount = FullMath.mulDiv(
                    uint256(-swapTransaction.amountSpecified),
                    amountToken0,
                    amountToken1
                );
            }
            poolManager.burn(swapTransaction.receiver, input.toId(), uint256(-swapTransaction.amountSpecified));
            transactions.pop();
        }
    }

    function _afterSwap(
        address,
        PoolKey calldata key, 
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector, int128 amountOut)
    {
        // ready batch to be cleared
        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];
        if (_isSettlementSwap(hookData) && batchState.transactions.length != 0) {
            int128 _amountOut = params.zeroForOne
                ? BalanceDeltaLibrary.amount1(swapDelta)
                : BalanceDeltaLibrary.amount0(swapDelta);
            if (_amountOut <= 0) return (BaseHook.afterSwap.selector, 0);

            Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
            poolManager.mint(address(this), outputCurrency.toId(), uint256(uint128(_amountOut)));
            clearTransactions(
                batchState.transactions,
                batchState.amountToken0, 
                batchState.amountToken1, 
                key);

            return (BaseHook.afterSwap.selector, _amountOut);
        } else if (batchState.transactions.length >= BATCH_FREQUENCY) {
            // give the settlement router the stake to clear the batch
            (batchState.setRoutStake, batchState.setRoutStakeZeroForOne) = _calculateSwap(
                batchState.clearingPriceX96,
                batchState.amountToken0,
                batchState.amountToken1
            );
            Currency outputCurrency = batchState.setRoutStakeZeroForOne ? key.currency1 : key.currency0;
            poolManager.mint(address(settlementRouter), outputCurrency.toId(), uint256(batchState.setRoutStake));

            settlementRouter.readyClear(
                key,
                batchState.setRoutStake,
                batchState.setRoutStakeZeroForOne,
                batchState.lowerSqrtClearingPriceX96,
                batchState.upperSqrtClearingPriceX96
            );
        }
        return (BaseHook.afterSwap.selector, 0);
    }
}