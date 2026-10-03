// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapSim} from "./SwapSim.sol";
import {BatchingHook} from "./BatchingHook.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract SettlementRouter is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    error OnlySelf();

    struct ClearState {
        bool clearable;
        uint256 amountToBalence;
        bool zeroForOne;
        uint160 lowerSqrtClearingPriceX96;
        uint160 upperSqrtClearingPriceX96;
    }

    IPoolManager public immutable poolManager;
    BatchingHook public batchingHook;
    mapping(PoolId => ClearState) public clearStates;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function setBatchingHook(address _batchingHook) external {
        batchingHook = BatchingHook(_batchingHook);
    }

    function _simulateSwap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amount,
        uint160 sqrtPriceLimitX96
    ) external view returns (int128 amount0Delta, int128 amount1Delta, uint160 sqrtPriceAfterX96) {
        if (msg.sender != address(this)) revert OnlySelf();
        return SwapSim.simulateSwap(poolManager, key, zeroForOne, amount, sqrtPriceLimitX96);
    }

    function _TestSwap(
        ClearState storage clearState,
        PoolKey calldata key
    ) internal view returns(bool valid) { 
        uint160 sqrtPriceLimitX96 = clearState.zeroForOne 
            ? clearState.lowerSqrtClearingPriceX96 
            : clearState.upperSqrtClearingPriceX96;

        try this._simulateSwap(key, clearState.zeroForOne, clearState.amountToBalence, sqrtPriceLimitX96)
            returns (int128, int128, uint160)
        {
            return true;
        } catch {
            return false;
        }
    }

    function _initSettlementswap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal {
        bytes memory data = abi.encode(
            key,
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96
        );

        poolManager.unlock(data);
    }

    function _voidBatch(
        PoolKey calldata key,
        uint256 stake,
        bool zeroForOne
    ) internal {
        PoolId poolId = key.toId();
        delete clearStates[poolId];
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        bytes memory data = abi.encode(
            input,
            int256(stake)
        );

        batchingHook.lockPool(poolId);
        poolManager.unlock(data);
        batchingHook.revertBatch(key);
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        if (data.length == 64) {
            (Currency input, uint256 stake) = abi.decode(data, (Currency, uint256));
            poolManager.burn(address(batchingHook), input.toId(), uint256(stake));
        } else {
            (
                PoolKey memory key,
                bool zeroForOne,
                int256 amountSpecified,
                uint160 sqrtPriceLimitX96
            ) = abi.decode(
                data,
                (PoolKey, bool, int256, uint160)
            );

            poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                abi.encode(address(this))
            );
        }
        return "";
    }

    function canClear(PoolKey calldata key) public view returns (bool valid) {
        ClearState storage clearState = clearStates[key.toId()];
        return clearState.clearable;
    }

    function clearBatch(PoolKey calldata key) external {
        if (!canClear(key)) revert("Batch cannot be cleared");

        ClearState storage clearState = clearStates[key.toId()];
        if (_TestSwap(clearState, key)) {
            uint160 sqrtPriceLimitX96 = clearState.zeroForOne 
                ? clearState.lowerSqrtClearingPriceX96 
                : clearState.upperSqrtClearingPriceX96;

            _initSettlementswap(
                key, 
                clearState.zeroForOne, 
                int256(clearState.amountToBalence), 
                sqrtPriceLimitX96);
        } else {
            _voidBatch(
                key,
                clearState.amountToBalence,
                clearState.zeroForOne
            );
        }
    }

    function readyClear(
        PoolKey calldata key, 
        uint256 amountToBalence, 
        bool zeroForOne,
        uint160 lowerPriceLimitX96, 
        uint160 upperPriceLimitX96) external {
            
        ClearState storage clearState = clearStates[key.toId()];
        clearState.clearable = true;
        clearState.amountToBalence = amountToBalence;
        clearState.zeroForOne = zeroForOne;
        clearState.lowerSqrtClearingPriceX96 = lowerPriceLimitX96;
        clearState.upperSqrtClearingPriceX96 = upperPriceLimitX96;
    }
}