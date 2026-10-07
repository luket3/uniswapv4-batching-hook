// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
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
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

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
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;
	using SafeCast for int256;

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

    function _swapExactInput(uint256 amountIn, bool zeroForOne) internal returns (uint256 amountOut) {
        Currency outCurrency = zeroForOne ? currency1 : currency0;
        uint256 balanceBefore = outCurrency.balanceOf(address(this));

        swapRouter.swap({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        amountOut = outCurrency.balanceOf(address(this)) - balanceBefore;
    }

    function test_testPriceMovement() public {
        uint256 amount0 = 200;
        uint256 amount1 = 100;
        uint160 lowerSqrtPriceX96 = TickMath.MIN_SQRT_PRICE;
        uint160 upperSqrtPriceX96 = TickMath.MAX_SQRT_PRICE;
        uint256 snapshotId = vm.snapshotState();

        _swapExactInput(amount0, true);
        _swapExactInput(amount1, false);
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
        _swapExactInput(balancingAmount, zeroForOne);
        (uint160 balancingSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        assertEq(
            balancingSqrtPriceX96,
            sequentialSqrtPriceX96,
            "calculated balancing swap should match the sequential exact-input final price"
        );
    }

    function test_balOutputAmount() public {
        uint256 amount0 = 1e18;
        uint256 amount1 = 5e17;
        uint160 lowerSqrtPriceX96 = TickMath.MIN_SQRT_PRICE;
        uint160 upperSqrtPriceX96 = TickMath.MAX_SQRT_PRICE;

        (uint256 balancingAmount, bool zeroForOne) = balanceCalc.getAmountToBalance(
            poolManager,
            key,
            amount0,
            amount1,
            upperSqrtPriceX96,
            lowerSqrtPriceX96
        );
        assertGt(balancingAmount, 0, "balancing calculation should return a positive trade amount");

        uint256 snapshotId = vm.snapshotState();

        // Reference: plain exact-input swap with the same amount and direction
        uint256 normalOutput1 = _swapExactInput(amount0, true);
        uint256 normalOutput0 = _swapExactInput(amount1, false);

        assertTrue(vm.revertToState(snapshotId), "pool state should restore before comparison");

        // Balancing swap from the identical starting pool state
        uint256 settledOutput = _swapExactInput(balancingAmount, zeroForOne);
        uint256 amountOut0;
        uint256 amountOut1;
        if (zeroForOne) {
            amountOut0 = amount0 - balancingAmount;
            amountOut1 = amount1 + settledOutput;
        } else {
            amountOut1 = amount1 - balancingAmount;
            amountOut0 = amount0 + settledOutput;
        }

        assertGe(
            amountOut0,
            normalOutput0,
            "should produce more token0"
        );
        assertGe(
            amountOut1,
            normalOutput1,
            "should produce more token1"
        );
    }

    function test_Revert() public {
        uint256 amount0 = 1e18;
        uint256 amount1 = 5e17;
        uint160 lowerSqrtPriceX96 = 78968337965930903587191341194;
        uint160 upperSqrtPriceX96 = TickMath.MAX_SQRT_PRICE;

        // should revert if lower bound is violated
        vm.expectRevert(BalanceCalc.PriceLimitExceeded.selector);
        balanceCalc.getAmountToBalance(
            poolManager,
            key,
            amount0,
            amount1,
            upperSqrtPriceX96,
            lowerSqrtPriceX96
        );

        // should revert if upper bound is violated
        upperSqrtPriceX96 = 79492336248235127403565567700;
        vm.expectRevert(BalanceCalc.PriceLimitExceeded.selector);
        balanceCalc.getAmountToBalance(
            poolManager,
            key,
            amount1,
            amount0,
            upperSqrtPriceX96,
            lowerSqrtPriceX96
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