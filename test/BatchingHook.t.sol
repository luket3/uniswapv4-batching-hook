// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {BatchingHook} from "../src/BatchingHook.sol";
import {SettlementRouter} from "../src/SettlementRouter.sol";

import {BaseTest} from "./utils/BaseTest.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract PointsHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    BatchingHook hook;
    SettlementRouter settlementRouter;
    PoolId poolId;
    PoolKey key;

    Currency currency1;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();

        (, currency1) = deployCurrencyPair();
        settlementRouter = new SettlementRouter(poolManager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("BatchingHook.sol:BatchingHook", constructorArgs, flags);
        hook = BatchingHook(flags);

        settlementRouter.setBatchingHook(address(hook));
        hook.setSettlementRouter(address(settlementRouter));

        // Create the pool
        key = PoolKey(
            Currency.wrap(address(0)),
            currency1,
            3000,
            60,
            IHooks(hook)
        );
        poolId = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        deal(address(this), 200 ether);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                Constants.SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                uint128(100e18)
            );

        (tokenId, ) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            100e18,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp + 1,
            hook.getHookData(address(this))
        );
    }

    function test_asyncSwap() public {
        uint256 balance0Before = Currency.wrap(address(0)).balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        // Perform a test swap //
        int256 amountSpecified = -1e18;
        bool zeroForOne = true;
        swapRouter.swap{value: uint256(-amountSpecified)}({
            amountSpecified: amountSpecified,
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hook.getHookData(address(this)),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 balance0After = Currency.wrap(address(0)).balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        // user paid token0
        assertEq(balance0Before - balance0After, 1e18);

        // user did not recieve token1 (AsyncSwap)
        assertEq(balance1Before, balance1After);
    }

    function test_outcome() public {
        // Perform a second swap //

        int256 amountSpecified = -1e18;
        bool zeroForOne = true;
        swapRouter.swap{value: uint256(-amountSpecified)}({
            amountSpecified: amountSpecified,
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hook.getHookData(address(this)),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        swapRouter.swap{value: uint256(-amountSpecified)}({
            amountSpecified: amountSpecified,
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hook.getHookData(address(this)),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }
}