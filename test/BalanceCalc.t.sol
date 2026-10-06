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
import {console} from "forge-std/console.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {BalanceCalc} from "../src/BalanceCalc.sol";

contract BalanceCalcHarness {
    // Exposes the internal library function to tests through a deployed harness.
    function getAmountToBalance(
		IPoolManager poolManager,
		PoolKey memory key,
		uint256 amountIn0,
		uint256 amountIn1,
		uint160 sqrtPriceUpperX96,
		uint160 sqrtPriceLowerX96
    ) external view returns (uint256 amount, bool zeroForOne) {
        return BalanceCalc.getAmountToBalance(
            poolManager,
            key,
            amountIn0,
            amountIn1,
            sqrtPriceUpperX96,
            sqrtPriceLowerX96);
    }
}

contract BalanceCalcTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    BalanceCalcHarness balanceCalc;
    PoolKey key;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        balanceCalc = new BalanceCalcHarness();

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Full-range liquidity remains active while the narrow position adds initialized ticks to cross.
        _addLiquidity(TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), 100e18);
        _addLiquidity(-120, 120, 50e18);
    }

    function test_balancingSwapMatchesSequentialExactInputSwaps() public {
        uint256 amount0 = 200;
        uint256 amount1 = 100;
        uint160 lowerSqrtPriceX96 = TickMath.MIN_SQRT_PRICE;
        uint160 upperSqrtPriceX96 = TickMath.MAX_SQRT_PRICE;
        uint256 snapshotId = vm.snapshotState();

        swapRouter.swap({
            amountSpecified: -int256(amount0),
            amountLimit: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swap({
            amountSpecified: -int256(amount1),
            amountLimit: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        (uint160 sequentialSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        assertTrue(vm.revertToState(snapshotId), "pool state should restore before comparison");
        (uint256 balancingAmount, bool zeroForOne) = balanceCalc.getAmountToBalance(
            poolManager,
            key,
            amount0,
            amount1,
            upperSqrtPriceX96,
            lowerSqrtPriceX96
        );
        assertGt(balancingAmount, 0, "test inputs should produce a balancing swap");

        swapRouter.swap({
            amountSpecified: -int256(balancingAmount),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        (uint160 balancingSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        assertEq(
            balancingSqrtPriceX96,
            sequentialSqrtPriceX96,
            "calculated balancing swap should match the sequential exact-input final price"
        );
    }

    function test_swapGasFee() public {
        swapRouter.swap({
            amountSpecified: -int256(999999999999999),
            amountLimit: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function test_calcGasFee() view public {
        balanceCalc.getAmountToBalance(
            poolManager,
            key,
            1e18,
            1e16,
            TickMath.MAX_SQRT_PRICE,
            TickMath.MIN_SQRT_PRICE
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