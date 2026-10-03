// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SwapSim} from "../src/SwapSim.sol";

contract SwapSimTestHarness {
    // Exposes the internal library function to tests through a deployed harness.
    function simulate(
        IPoolManager poolManager,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external view returns (int128 amount0Delta, int128 amount1Delta, uint160 sqrtPriceAfterX96) {
        return SwapSim.simulateSwap(poolManager, key, zeroForOne, amountIn, sqrtPriceLimitX96);
    }
}

contract SwapSimTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    SwapSimTestHarness simulator;
    PoolKey key;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        simulator = new SwapSimTestHarness();

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Full-range liquidity remains active while the narrow position adds initialized ticks to cross.
        _addLiquidity(TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), 100e18);
        _addLiquidity(-120, 120, 50e18);
    }

    // Check token0 input quoting, tick crossing, and that simulation leaves the pool untouched.
    function test_simulateZeroForOneAcrossInitializedTick() public {
        uint256 amountIn = 2e18;
        uint160 sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
        (uint160 sqrtPriceBefore,,,) = poolManager.getSlot0(key.toId());

        (int128 expectedAmount0, int128 expectedAmount1, uint160 expectedSqrtPrice) = simulator.simulate(
            poolManager,
            key,
            true,
            amountIn,
            sqrtPriceLimitX96
        );

        (uint160 sqrtPriceAfterQuote,,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceAfterQuote, sqrtPriceBefore, "simulation must not mutate pool state");
        assertEq(uint256(uint128(-expectedAmount0)), amountIn, "exact input token0 delta");
        assertGt(expectedAmount1, 0, "token1 should be received");
        assertLt(expectedSqrtPrice, TickMath.getSqrtPriceAtTick(-120), "quote should cross lower tick");

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        swapRouter.swap({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (uint160 actualSqrtPrice,,,) = poolManager.getSlot0(key.toId());
        assertEq(balance0Before - currency0.balanceOfSelf(), amountIn);
        assertEq(currency1.balanceOfSelf() - balance1Before, uint256(uint128(expectedAmount1)));
        assertEq(actualSqrtPrice, expectedSqrtPrice, "simulated final price should match execution");
    }

    // Check the reverse direction against real execution across the upper initialized tick.
    function test_simulateOneForZeroAcrossInitializedTick() public {
        uint256 amountIn = 2e18;
        uint160 sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
        (uint160 sqrtPriceBefore,,,) = poolManager.getSlot0(key.toId());

        (int128 expectedAmount0, int128 expectedAmount1, uint160 expectedSqrtPrice) = simulator.simulate(
            poolManager,
            key,
            false,
            amountIn,
            sqrtPriceLimitX96
        );

        (uint160 sqrtPriceAfterQuote,,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceAfterQuote, sqrtPriceBefore, "simulation must not mutate pool state");
        assertEq(uint256(uint128(-expectedAmount1)), amountIn, "exact input token1 delta");
        assertGt(expectedAmount0, 0, "token0 should be received");
        assertGt(expectedSqrtPrice, TickMath.getSqrtPriceAtTick(120), "quote should cross upper tick");

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        swapRouter.swap({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (uint160 actualSqrtPrice,,,) = poolManager.getSlot0(key.toId());
        assertEq(currency0.balanceOfSelf() - balance0Before, uint256(uint128(expectedAmount0)));
        assertEq(balance1Before - currency1.balanceOfSelf(), amountIn);
        assertEq(actualSqrtPrice, expectedSqrtPrice, "simulated final price should match execution");
    }

    function test_simulateSwapRevertCanBeCaught() public view {
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        try simulator.simulate(
            poolManager,
            key,
            true,
            1e18,
            currentSqrtPriceX96
        ) returns (int128, int128, uint160) {
            assertTrue(false, "expected invalid sqrt price limit error");
        } catch (bytes memory reason) {
            bytes4 errorSelector;
            assembly ("memory-safe") {
                errorSelector := mload(add(reason, 0x20))
            }
            assertEq(errorSelector, SwapSim.InvalidSqrtPriceLimit.selector);
        }
    }

    function test_simulateSwapRevertsWhenInputWouldCrossPriceLimit() public {
        vm.expectRevert(SwapSim.PriceLimitExceeded.selector);
        simulator.simulate(
            poolManager,
            key,
            true,
            2e18,
            TickMath.getSqrtPriceAtTick(-60)
        );
    }

    // Adds a position over the requested range using the test's current pool price.
    function _addLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity) private {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidity,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp + 1,
            ""
        );
    }
}
