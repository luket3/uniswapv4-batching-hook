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
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BatchingHook} from "../src/BatchingHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Minimal interface for calling the Uniswap Universal Router on mainnet.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice fork tests that deploy BatchingHook against the canonical Ethereum mainnet
///         PoolManager (0x000000000004444c5dc75cB358380D2e3dE08A90) and submit async
///         swaps via two mainnet-deployed routers that implement IMsgSender:
///           - hookmate V4 Router   (0xA4B6DB94b3017e2b7f17055Ded97D117ed5F551A)
///           - Uniswap Universal Router (0x66a9893cc07d91d95644aedd05d03f95e1dba8af)
/// @dev set MAINNET_RPC_URL; tests are skipped automatically when it is absent
contract BatchingHookForkTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Uniswap Universal Router (v4-capable, implements IMsgSender via Dispatcher._getLocker)
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // V4 action bytes: SWAP_EXACT_IN_SINGLE (0x06), SETTLE_ALL (0x0c), TAKE_ALL (0x0f)
    bytes constant V4_ACTIONS = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));

    // Universal Router command: V4_SWAP = 0x10
    bytes constant UR_COMMANDS = abi.encodePacked(uint8(0x10));

    BatchingHook hook;
    PoolKey key;
    PoolId poolId;
    Currency currency0;
    Currency currency1;
    int24 tickLower;
    int24 tickUpper;

    receive() external payable {}

    /// @notice forks mainnet, deploys the hook to the canonical PoolManager, creates a
    ///         full-range ETH/ERC-20 pool at 1:1, and seeds it with 100 ETH of liquidity;
    ///         skips the test if MAINNET_RPC_URL is not set
    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        // deployArtifactsAndLabel reads block.chainid == 1 and wires up the deployed
        // mainnet contracts: PoolManager, PositionManager, Permit2, hookmate V4 Router
        deployArtifactsAndLabel();

        currency0 = Currency.wrap(address(0));
        (, currency1) = deployCurrencyPair();

        // deploy hook to an address whose lower bits encode the required permission flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
            ^ (0x5555 << 144)
        );
        deployCodeTo("BatchingHook.sol:BatchingHook", abi.encode(poolManager), flags);
        hook = BatchingHook(flags);
        vm.label(flags, "BatchingHook");

        hook.addRouter(address(swapRouter));
        hook.addRouter(UNIVERSAL_ROUTER);

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        deal(address(this), 200 ether);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(100e18)
        );
        positionManager.mint(
            key, tickLower, tickUpper, 100e18,
            amount0 + 1, amount1 + 1,
            address(this), block.timestamp + 1, ""
        );
    }

    /// @notice queues one async swap via the hookmate V4 Router against the mainnet PoolManager
    function _queueSwap(address trader, uint256 amountIn, bool zeroForOne) internal {
        MockERC20 token = MockERC20(Currency.unwrap(currency1));

        if (zeroForOne) {
            vm.deal(trader, trader.balance + amountIn);
        } else {
            token.mint(trader, amountIn);
            vm.prank(trader);
            token.approve(address(swapRouter), type(uint256).max);
        }

        vm.prank(trader);
        swapRouter.swap{value: zeroForOne ? amountIn : 0}(
            -int256(amountIn),
            0,
            zeroForOne,
            key,
            "",
            address(this),
            block.timestamp + 1
        );
    }

    /// @notice queues one async swap via the Uniswap Universal Router.
    ///         ERC-20 inputs are approved through the canonical Permit2 contract so the
    ///         Universal Router can pull them during SETTLE_ALL.
    function _queueSwapViaUniversalRouter(address trader, uint256 amountIn, bool zeroForOne) internal {
        Currency inputCurrency  = zeroForOne ? currency0 : currency1;
        Currency outputCurrency = zeroForOne ? currency1 : currency0;
        MockERC20 token = MockERC20(Currency.unwrap(currency1));

        if (zeroForOne) {
            vm.deal(trader, trader.balance + amountIn);
        } else {
            token.mint(trader, amountIn);
            // Universal Router pulls ERC-20s via Permit2
            vm.prank(trader);
            token.approve(address(permit2), type(uint256).max);
            vm.prank(trader);
            IAllowanceTransfer(address(permit2)).approve(
                address(token),
                UNIVERSAL_ROUTER,
                type(uint160).max,
                type(uint48).max
            );
        }

        // Encode v4 swap: SWAP_EXACT_IN_SINGLE + SETTLE_ALL + TAKE_ALL
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        actionParams[1] = abi.encode(inputCurrency, type(uint256).max); // SETTLE_ALL
        actionParams[2] = abi.encode(outputCurrency, uint256(0));       // TAKE_ALL (0 min; output deferred)

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(V4_ACTIONS, actionParams);

        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: zeroForOne ? amountIn : 0}(
            UR_COMMANDS,
            inputs,
            block.timestamp + 1
        );
    }

    /// @notice verifies that five ETH-to-token swaps submitted via the hookmate V4 Router
    ///         against the mainnet PoolManager are correctly queued by the batching hook
    ///         and settled by clearBatch, with each trader receiving proportional token output
    function test_fork_swapRouter_fiveSwapsQueueAndClear() public {
        address[5] memory traders = [
            address(0xF01),
            address(0xF02),
            address(0xF03),
            address(0xF04),
            address(0xF05)
        ];

        for (uint256 i = 0; i < 5; i++) {
            _queueSwap(traders[i], 1e18, true);
        }

        assertTrue(hook.clearBatch(key), "clearBatch should succeed after 5 queued swaps");

        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        for (uint256 i = 0; i < 5; i++) {
            assertGt(token1.balanceOf(traders[i]), 0, "trader should receive token1 after clearBatch");
        }
    }

    /// @notice verifies that clearBatch reverts with BatchTooSmall when fewer than
    ///         MIN_BATCH_SIZE swaps have been queued
    function test_fork_swapRouter_revertsBelowMinBatchSize() public {
        _queueSwap(address(0xF01), 1e18, true);
        _queueSwap(address(0xF02), 1e18, true);
        _queueSwap(address(0xF03), 1e18, true);
        _queueSwap(address(0xF04), 1e18, true);

        vm.expectRevert(BatchingHook.BatchTooSmall.selector);
        hook.clearBatch(key);
    }

    /// @notice verifies that a mixed batch of ETH-to-token and token-to-ETH swaps via
    ///         the hookmate V4 Router clears successfully and pays both sides their output
    function test_fork_swapRouter_mixedBatchBothSidesReceiveOutput() public {
        address[3] memory ethTraders   = [address(0xA01), address(0xA02), address(0xA03)];
        address[3] memory tokenTraders = [address(0xB01), address(0xB02), address(0xB03)];

        for (uint256 i = 0; i < 3; i++) {
            _queueSwap(ethTraders[i],   1e18, true);
        }
        for (uint256 i = 0; i < 3; i++) {
            _queueSwap(tokenTraders[i], 1e18, false);
        }

        assertTrue(hook.clearBatch(key), "mixed batch should clear");

        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        for (uint256 i = 0; i < 3; i++) {
            assertGt(token1.balanceOf(ethTraders[i]), 0, "ETH trader should receive token1");
        }
        for (uint256 i = 0; i < 3; i++) {
            assertGt(currency0.balanceOf(tokenTraders[i]), 0, "token1 trader should receive ETH");
        }
    }

    /// @notice verifies that five ETH-to-token swaps submitted via the Uniswap Universal Router
    ///         are correctly queued and settled by clearBatch
    function test_fork_universalRouter_fiveSwapsQueueAndClear() public {
        address[5] memory traders = [
            address(0xC01),
            address(0xC02),
            address(0xC03),
            address(0xC04),
            address(0xC05)
        ];

        for (uint256 i = 0; i < 5; i++) {
            _queueSwapViaUniversalRouter(traders[i], 1e18, true);
        }

        assertTrue(hook.clearBatch(key), "clearBatch should succeed after 5 UR swaps");

        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        for (uint256 i = 0; i < 5; i++) {
            assertGt(token1.balanceOf(traders[i]), 0, "trader should receive token1 after clearBatch");
        }
    }

    /// @notice verifies that a mixed batch of ETH-to-token and token-to-ETH swaps via
    ///         the Uniswap Universal Router clears successfully and pays both sides their output
    function test_fork_universalRouter_mixedBatchBothSidesReceiveOutput() public {
        address[3] memory ethTraders   = [address(0xD01), address(0xD02), address(0xD03)];
        address[3] memory tokenTraders = [address(0xE01), address(0xE02), address(0xE03)];

        for (uint256 i = 0; i < 3; i++) {
            _queueSwapViaUniversalRouter(ethTraders[i],   1e18, true);
        }
        for (uint256 i = 0; i < 3; i++) {
            _queueSwapViaUniversalRouter(tokenTraders[i], 1e18, false);
        }

        assertTrue(hook.clearBatch(key), "mixed batch should clear");

        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        for (uint256 i = 0; i < 3; i++) {
            assertGt(token1.balanceOf(ethTraders[i]), 0, "ETH trader should receive token1");
        }
        for (uint256 i = 0; i < 3; i++) {
            assertGt(currency0.balanceOf(tokenTraders[i]), 0, "token1 trader should receive ETH");
        }
    }
}
