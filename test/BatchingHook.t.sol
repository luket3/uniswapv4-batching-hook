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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BatchingHook} from "../src/BatchingHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {console} from "forge-std/console.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceCalc} from "../src/BalanceCalc.sol";

contract BatchingHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    BatchingHook hook;
    PoolId poolId;
    PoolKey key;
    Currency currency0;
    Currency currency1;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    PoolSwapTest limitRouter;

    receive() external payable {}

    function setUp() public {
        deployArtifactsAndLabel();
        currency0 = Currency.wrap(address(0));
        (, currency1) = deployCurrencyPair();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("BatchingHook.sol:BatchingHook", constructorArgs, flags);
        hook = BatchingHook(flags);

        // Create the pool
        key = PoolKey(
            currency0,
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
        limitRouter = new PoolSwapTest(poolManager);
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

        assertEq(balance0Before - balance0After, 1e18);
        assertEq(balance1Before, balance1After);
    }

    function test_CurrencyRecOnClear() public {
        uint256 balance0Before = Currency.wrap(address(0)).balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

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
        
        hook.clearBatch(key);
        uint256 balance0After = Currency.wrap(address(0)).balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();
        assertEq(balance0Before - balance0After, 1e18*2);
        assert(balance1Before != balance1After);
    }

    function _swapExactInput(address trader, uint256 amountIn, bool zeroForOne) internal {
        vm.prank(trader);
        swapRouter.swap{value: zeroForOne ? amountIn : 0}({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hook.getHookData(trader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function test_sameDirSameClearPrice() public {
        address firstTrader = address(0xA11CE);
        address secondTrader = address(0xB0B);
        uint256 firstAmountIn = 1e18;
        uint256 secondAmountIn = 2e18;
        vm.deal(firstTrader, firstAmountIn);
        vm.deal(secondTrader, secondAmountIn);

        _swapExactInput(firstTrader, firstAmountIn, true);
        _swapExactInput(secondTrader, secondAmountIn, true);

        assertTrue(hook.clearBatch(key), "batch should clear successfully");

        uint256 firstAmountOut = currency1.balanceOf(firstTrader);
        uint256 secondAmountOut = currency1.balanceOf(secondTrader);
        assertGt(firstAmountOut, 0, "first order should receive token1");
        assertGt(secondAmountOut, 0, "second order should receive token1");

        uint256 firstPriceProduct = firstAmountOut * secondAmountIn;
        uint256 secondPriceProduct = secondAmountOut * firstAmountIn;
        uint256 productDifference = firstPriceProduct > secondPriceProduct
            ? firstPriceProduct - secondPriceProduct
            : secondPriceProduct - firstPriceProduct;
        assertLe(productDifference, secondAmountIn, "orders should receive token1 at the same clearing price");
    }

    function _assertSameRate(uint256 outputA, uint256 inputA, uint256 outputB, uint256 inputB) private pure {
        uint256 productA = outputA * inputB;
        uint256 productB = outputB * inputA;
        uint256 difference = productA > productB ? productA - productB : productB - productA;
        assertLe(difference, inputA + inputB, "same-direction orders should clear at the same price");
    }

    function test_mixDirSameClearPrice() public {
        address token0TraderA = address(0xA11CE);
        address token0TraderB = address(0xB0B);
        address token1TraderA = address(0xCAFE);
        address token1TraderB = address(0xD00D);
        uint256 amountToken0A = 2e18;
        uint256 amountToken0B = 1e18;
        uint256 amountToken1A = 1e18;
        uint256 amountToken1B = 0.5e18;
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        vm.deal(token0TraderA, amountToken0A);
        vm.deal(token0TraderB, amountToken0B);
        token1.mint(token1TraderA, amountToken1A);
        token1.mint(token1TraderB, amountToken1B);
        vm.prank(token1TraderA);
        token1.approve(address(limitRouter), type(uint256).max);
        vm.prank(token1TraderA);
        token1.approve(address(limitRouter), type(uint256).max);

        _swapExactInput(token0TraderA, amountToken0A, true);
        _swapExactInput(token0TraderB, amountToken0B, true);
        _swapExactInput(token1TraderA, amountToken1A, false);
        _swapExactInput(token1TraderB, amountToken1B, false);

        assertTrue(hook.clearBatch(key), "mixed-direction batch should clear");

        uint256 token0OutA = currency0.balanceOf(token1TraderA);
        uint256 token0OutB = currency0.balanceOf(token1TraderB);
        uint256 token1OutA = currency1.balanceOf(token0TraderA);
        uint256 token1OutB = currency1.balanceOf(token0TraderB);

        assertGt(token1OutA, 0, "first token0 seller should receive token1");
        assertGt(token1OutB, 0, "second token0 seller should receive token1");
        assertGt(token0OutA, 0, "first token1 seller should receive token0");
        assertGt(token0OutB, 0, "second token1 seller should receive token0");

        _assertSameRate(token1OutA, amountToken0A, token1OutB, amountToken0B);
        _assertSameRate(token0OutA, amountToken1A, token0OutB, amountToken1B);
    }
    
    function _swapWithLimit(address trader, uint256 amountIn, bool zeroForOne, uint160 limit) internal {
        bytes memory hookData = hook.getHookData(trader); // before the prank
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        if (zeroForOne) {
            vm.deal(trader, trader.balance + amountIn);
        } else {
            token1.mint(trader, amountIn);
            vm.prank(trader);
            token1.approve(address(limitRouter), type(uint256).max);
        }

        vm.prank(trader);
        limitRouter.swap{value: zeroForOne ? amountIn : 0}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function test_batchReverted() public {
        address trader0 = address(0xA11CE);
        address trader1 = address(0xB0B);
        address trader2 = address(0xCAFE);
        uint256 amount0 = 2e18;
        uint256 amount1 = 1e18;
        uint256 amount2 = 1e18;

        _swapWithLimit(trader0, amount0, true, TickMath.MIN_SQRT_PRICE + 1);
        _swapWithLimit(trader1, amount1, false, TickMath.MAX_SQRT_PRICE - 1);
        _swapWithLimit(trader2, amount2, false, 69259048059136640427579878881);

        assertFalse(hook.clearBatch(key), "mixed-direction batch should clear");

        uint256 balTrader0 = currency0.balanceOf(trader0);
        uint256 balTrader1 = currency1.balanceOf(trader1);
        uint256 balTrader2 = currency1.balanceOf(trader2);

        assertEq(amount0, balTrader0);
        assertEq(amount1, balTrader1);
        assertEq(amount2, balTrader2);
    }
}