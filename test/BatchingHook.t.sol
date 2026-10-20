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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MsgSenderPoolSwapTest} from "./utils/MsgSenderPoolSwapTest.sol";

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
    MsgSenderPoolSwapTest limitRouter;

    /// @notice swap specification used by permutation and batch-vs-sequential tests
    struct SwapSpec {
        address trader;
        uint256 amountIn;
        bool zeroForOne;
    }

    /// @notice allows the test contract to receive native ETH from the swap router
    receive() external payable {}

    /// @notice deploys all protocol contracts, creates a native/ERC-20 pool at 1:1,
    ///         seeds it with full-range liquidity, and wires up the batching hook
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
            ""
        );
        limitRouter = new MsgSenderPoolSwapTest(poolManager);

        hook.addRouter(address(swapRouter));
        hook.addRouter(address(limitRouter));
    }

    /// @notice asserts that a single queued swap is asynchronous: input is consumed,
    ///         output is withheld, and the pool price does not move
    /// @param amountIn the exact input amount for the swap
    /// @param zeroForOne true if swapping currency0 for currency1
    function _assertAsyncSwap(uint256 amountIn, bool zeroForOne) internal {
        (uint160 sqrtPriceBefore,,,) = poolManager.getSlot0(poolId);
        uint256 inputBefore  = zeroForOne ? currency0.balanceOfSelf() : currency1.balanceOfSelf();
        uint256 outputBefore = zeroForOne ? currency1.balanceOfSelf() : currency0.balanceOfSelf();

        swapRouter.swap{value: zeroForOne ? amountIn : 0}({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 inputAfter  = zeroForOne ? currency0.balanceOfSelf() : currency1.balanceOfSelf();
        uint256 outputAfter = zeroForOne ? currency1.balanceOfSelf() : currency0.balanceOfSelf();
        (uint160 sqrtPriceAfter,,,) = poolManager.getSlot0(poolId);

        assertEq(inputBefore - inputAfter, amountIn, "input not consumed");
        assertEq(outputAfter, outputBefore,           "output must not be returned");
        assertEq(sqrtPriceAfter, sqrtPriceBefore,     "pool price must not move");
    }

    /// @notice verifies async swap behaviour when the input token is native ETH (currency0 -> currency1)
    function test_asyncSwap_nativeInput() public {
        _assertAsyncSwap(1e18, true);   // ETH -> token1
    }

    /// @notice verifies async swap behaviour when the input token is an ERC-20 (currency1 -> currency0)
    function test_asyncSwap_erc20Input() public {
        _assertAsyncSwap(1e18, false);  // token1 -> ETH
    }

    /// @notice verifies that after clearing a same-direction batch the caller's
    ///         input balance decreases by the total queued amount and output is received
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
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swap{value: uint256(-amountSpecified)}({
            amountSpecified: amountSpecified,
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        hook.clearBatchNoInterval(key);
        uint256 balance0After = Currency.wrap(address(0)).balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();
        assertEq(balance0Before - balance0After, 1e18*2);
        assert(balance1Before != balance1After);
    }

    /// @notice submits an exact-input swap via the swap router on behalf of a trader
    /// @param trader the address that will own the queued swap
    /// @param amountIn the exact input amount
    /// @param zeroForOne true if swapping currency0 for currency1
    function _swapExactInput(address trader, uint256 amountIn, bool zeroForOne) internal {
        vm.prank(trader);
        swapRouter.swap{value: zeroForOne ? amountIn : 0}({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    /// @notice asserts that two same-direction swaps cleared at the same exchange rate,
    ///         allowing 1 wei of rounding error per unit of input
    /// @param outputA output received by trader A
    /// @param inputA  input provided by trader A
    /// @param outputB output received by trader B
    /// @param inputB  input provided by trader B
    function _assertSameRate(uint256 outputA, uint256 inputA, uint256 outputB, uint256 inputB) private pure {
        uint256 productA = outputA * inputB;
        uint256 productB = outputB * inputA;
        uint256 difference = productA > productB ? productA - productB : productB - productA;
        assertLe(difference, inputA + inputB, "same-direction orders should clear at the same price");
    }

    /// @notice submits an exact-input swap via the limit router, minting tokens for the trader
    ///         as needed, with a wide price limit that always accepts the batch
    /// @param trader the address submitting the swap
    /// @param amountIn the exact input amount
    /// @param zeroForOne true if swapping currency0 for currency1
    /// @param limit the sqrtPriceLimitX96 passed to the pool
    function _swapWithLimit(address trader, uint256 amountIn, bool zeroForOne, uint160 limit) internal {
        bytes memory hookData = ""; // hookData unused; sender recovered via IMsgSender
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
            MsgSenderPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice verifies that a batch whose net direction violates all traders' price limits
    ///         is reverted and each trader's input is returned in full
    function test_batchReverted() public {
        uint256 snapBefore = vm.snapshotState();
        address trader0 = address(0xA11CE);
        address trader1 = address(0xB0B);
        address trader2 = address(0xCAFE);
        uint256 amount0 = 2e18;
        uint256 amount1 = 5e18;
        uint256 amount2 = 1e18;

        (uint160 sqrtStartPriceX96,,,) = poolManager.getSlot0(key.toId());
        _swapWithLimit(trader0, amount0, true, sqrtStartPriceX96);
        _swapWithLimit(trader1, amount1, false, sqrtStartPriceX96);
        _swapWithLimit(trader2, amount2, false, sqrtStartPriceX96);

        assertFalse(hook.clearBatchNoInterval(key), "mixed-direction batch should clear");

        uint256 balTrader0 = currency0.balanceOf(trader0);
        uint256 balTrader1 = currency1.balanceOf(trader1);
        uint256 balTrader2 = currency1.balanceOf(trader2);

        assertEq(amount0, balTrader0);
        assertEq(amount1, balTrader1);
        assertEq(amount2, balTrader2);
        vm.revertToState(snapBefore);
    }

    /// @notice verifies that the caller of clearBatch receives a gas rebate of
    ///         (286049 + 42135*n) * gasPrice * 1.1, taken from each token side in proportion
    ///         to the number of swaps in that direction, so every trader funds an equal share
    function test_clearBatchCallerCompensation() public {
        uint256 snapBefore = vm.snapshotState();
        address caller = address(0xC1EA);

        // Set a known gas environment.  gasPrice(15 gwei) < 2xbaseFee(20 gwei)
        // so the basefee cap does not activate.
        vm.fee(10 gwei);
        vm.txGasPrice(15 gwei);

        // Uneven direction counts (3 zeroForOne, 2 oneForZero) with equal total value
        // on each side at the 1:1 initialisation price.
        address[3] memory zfoTraders = [address(0xA1), address(0xA2), address(0xA3)];
        address[2] memory ofzTraders = [address(0xB1), address(0xB2)];
        uint256 zfoAmountIn = 1e18;
        uint256 ofzAmountIn = 1.5e18;
        for (uint256 i = 0; i < zfoTraders.length; i++) {
            _swapWithLimit(zfoTraders[i], zfoAmountIn, true, TickMath.MIN_SQRT_PRICE + 1);
        }
        for (uint256 i = 0; i < ofzTraders.length; i++) {
            _swapWithLimit(ofzTraders[i], ofzAmountIn, false, TickMath.MAX_SQRT_PRICE - 1);
        }

        // Pre-compute expected compensation.
        // n=5, effectiveGasPrice=15 gwei; at SQRT_PRICE_1_1 price=1 so token1 needs no conversion.
        uint256 n = 5;
        uint256 gasCost = (286049 + 42135 * n) * 15 gwei * 11;
        uint256 expectedComp0 = gasCost * zfoTraders.length / (10 * n);
        uint256 expectedComp1 = gasCost * ofzTraders.length / (10 * n);
        uint256 expectedPerTrader = gasCost / (10 * n);

        uint256 callerEthBefore  = currency0.balanceOf(caller);
        uint256 callerTok1Before = currency1.balanceOf(caller);

        vm.prank(caller);
        assertTrue(hook.clearBatchNoInterval(key), "clearBatch should succeed");

        uint256 comp0 = currency0.balanceOf(caller) - callerEthBefore;
        uint256 comp1 = currency1.balanceOf(caller) - callerTok1Before;

        assertEq(comp0, expectedComp0, "wrong token0 compensation");
        assertEq(comp1, expectedComp1, "wrong token1 compensation");

        // At 1:1 every trader's shortfall from a fee-free 1:1 fill is the value they
        // contributed to the rebate.  zeroForOne traders are paid from token1 that is
        // never swapped, so their share is exact (within rounding).
        for (uint256 i = 0; i < zfoTraders.length; i++) {
            uint256 shortfall = zfoAmountIn - currency1.balanceOf(zfoTraders[i]);
            assertApproxEqAbs(shortfall, expectedPerTrader, 1, "zeroForOne trader paid uneven compensation");
        }

        // oneForZero traders additionally absorb the pool fee on the small balancing swap
        // created by the uneven rebate, so allow a 0.5% tolerance.
        for (uint256 i = 0; i < ofzTraders.length; i++) {
            uint256 shortfall = ofzAmountIn - currency0.balanceOf(ofzTraders[i]);
            assertApproxEqRel(shortfall, expectedPerTrader, 0.005e18, "oneForZero trader paid uneven compensation");
        }

        vm.revertToState(snapBefore);
    }

    /// @notice verifies that clearBatch reverts with BatchTooSmall when fewer than
    ///         MIN_BATCH_SIZE swaps have been queued
    function test_clearBatch_revertsBeforeFiveSwaps() public {
        uint256 snapBefore = vm.snapshotState();

        // Queue only 4 swaps - one short of MIN_BATCH_SIZE.
        _swapWithLimit(address(0xAAAA), 1e17, true,  TickMath.MIN_SQRT_PRICE + 1);
        _swapWithLimit(address(0xBBBB), 1e17, false, TickMath.MAX_SQRT_PRICE - 1);
        _swapWithLimit(address(0xCCCC), 1e17, true,  TickMath.MIN_SQRT_PRICE + 1);
        _swapWithLimit(address(0xDDDD), 1e17, false, TickMath.MAX_SQRT_PRICE - 1);

        vm.expectRevert(BatchingHook.BatchTooSmall.selector);
        hook.clearBatch(key);

        vm.revertToState(snapBefore);
    }

    /// @notice verifies that clearBatch succeeds once exactly MIN_BATCH_SIZE swaps are queued
    function test_clearBatch_succeedsAfterFiveSwaps() public {
        uint256 snapBefore = vm.snapshotState();

        // Queue exactly MIN_BATCH_SIZE (5) swaps.
        _swapWithLimit(address(0xAAAA), 1e17, true,  TickMath.MIN_SQRT_PRICE + 1);
        _swapWithLimit(address(0xBBBB), 1e17, false, TickMath.MAX_SQRT_PRICE - 1);
        _swapWithLimit(address(0xCCCC), 1e17, true,  TickMath.MIN_SQRT_PRICE + 1);
        _swapWithLimit(address(0xDDDD), 1e17, false, TickMath.MAX_SQRT_PRICE - 1);
        _swapWithLimit(address(0xEEEE), 1e17, true,  TickMath.MIN_SQRT_PRICE + 1);

        assertTrue(hook.clearBatch(key), "clearBatch should succeed with 5 swaps");

        vm.revertToState(snapBefore);
    }

    // -- Permutation test helpers --

    /// @notice returns a deep copy of arr
    function _cloneArr(uint256[] memory arr) private pure returns (uint256[] memory copy) {
        copy = new uint256[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) copy[i] = arr[i];
    }

    /// @notice returns n! (n factorial)
    function _factorial(uint256 n) private pure returns (uint256 f) {
        f = 1;
        for (uint256 i = 2; i <= n; i++) f *= i;
    }

    /// @notice uses Heap's algorithm to enumerate all n! permutations of [0 .. n-1]
    /// @param n the number of elements to permute
    /// @return result array of all n! permutations
    function _generatePermutations(uint256 n) private pure returns (uint256[][] memory result) {
        uint256 count = _factorial(n);
        result = new uint256[][](count);
        uint256[] memory perm = new uint256[](n);
        for (uint256 k = 0; k < n; k++) perm[k] = k;
        uint256[] memory c = new uint256[](n);
        result[0] = _cloneArr(perm);
        uint256 idx = 1;
        uint256 hi = 1;
        while (hi < n) {
            if (c[hi] < hi) {
                if (hi % 2 == 0) {
                    (perm[0], perm[hi]) = (perm[hi], perm[0]);
                } else {
                    (perm[c[hi]], perm[hi]) = (perm[hi], perm[c[hi]]);
                }
                result[idx++] = _cloneArr(perm);
                c[hi]++;
                hi = 1;
            } else {
                c[hi] = 0;
                hi++;
            }
        }
    }

    /// @notice produces a Fisher-Yates shuffle of [0..n-1] deterministically keyed by seed
    /// @param n number of indices
    /// @param seed entropy source for the shuffle
    /// @return indices the shuffled index array
    function _shuffledIndices(uint256 n, uint256 seed) private pure returns (uint256[] memory indices) {
        indices = new uint256[](n);
        for (uint256 k = 0; k < n; k++) indices[k] = k;
        for (uint256 k = n - 1; k > 0; k--) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint256 j = seed % (k + 1);
            (indices[k], indices[j]) = (indices[j], indices[k]);
        }
    }

    /// @notice returns all n! permutations for n <= 4, otherwise 24 distinct random samples
    /// @param n number of swaps to permute
    /// @return array of permutation index arrays
    function _getPermutations(uint256 n) private pure returns (uint256[][] memory) {
        if (n <= 4) return _generatePermutations(n);
        uint256[][] memory perms = new uint256[][](24);
        for (uint256 k = 0; k < 24; k++) {
            perms[k] = _shuffledIndices(n, uint256(keccak256(abi.encode("perm-seed", k))));
        }
        return perms;
    }

    /// @notice submits a single SwapSpec via the limit router, funding the trader as needed
    /// @param s the swap specification containing trader address, amount, and direction
    function _submitSwapViaLimitRouter(SwapSpec memory s) private {
        MockERC20 token1contract = MockERC20(Currency.unwrap(currency1));
        bytes memory hookData = ""; // hookData unused; sender recovered via IMsgSender
        if (s.zeroForOne) {
            vm.deal(s.trader, s.amountIn);
        } else {
            token1contract.mint(s.trader, s.amountIn);
            vm.prank(s.trader);
            token1contract.approve(address(limitRouter), type(uint256).max);
        }
        vm.prank(s.trader);
        limitRouter.swap{value: s.zeroForOne ? s.amountIn : 0}(
            key,
            SwapParams({
                zeroForOne:        s.zeroForOne,
                amountSpecified:   -int256(s.amountIn),
                sqrtPriceLimitX96: s.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            MsgSenderPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice restores state to baseSnap, submits all swaps in the given order,
    ///         clears the batch, and returns per-trader outputs plus pool state
    /// @param specs the set of swaps to submit
    /// @param order index permutation defining submission order
    /// @param baseSnap snapshot id to restore before submitting
    /// @return outputs per-trader output amounts indexed by specs
    /// @return sqrtPrice pool sqrtPriceX96 after clearing
    /// @return liquidity pool liquidity after clearing
    /// @return hookBal0 hook's remaining currency0 claim balance
    /// @return hookBal1 hook's remaining currency1 claim balance
    function _runPermutation(
        SwapSpec[] memory specs,
        uint256[] memory order,
        uint256 baseSnap
    ) private returns (
        uint256[] memory outputs,
        uint160 sqrtPrice,
        uint128 liquidity,
        uint256 hookBal0,
        uint256 hookBal1
    ) {
        vm.revertToState(baseSnap);
        for (uint256 i = 0; i < order.length; i++) {
            _submitSwapViaLimitRouter(specs[order[i]]);
        }
        assertTrue(hook.clearBatchNoInterval(key), "batch clear failed");

        outputs = new uint256[](specs.length);
        for (uint256 i = 0; i < specs.length; i++) {
            Currency out = specs[i].zeroForOne ? currency1 : currency0;
            outputs[i] = out.balanceOf(specs[i].trader);
        }
        (sqrtPrice,,,) = poolManager.getSlot0(key.toId());
        liquidity  = poolManager.getLiquidity(key.toId());
        hookBal0   = poolManager.balanceOf(address(hook), currency0.toId());
        hookBal1   = poolManager.balanceOf(address(hook), currency1.toId());
    }

    /// @notice runs every provided permutation from baseSnap and checks two properties:
    ///         order-independence (identical outputs and pool state for every ordering) and
    ///         fairness (same-direction traders clear at a proportional rate)
    /// @param specs the fixed set of swaps to permute
    /// @param perms the permutations to test
    /// @param baseSnap snapshot taken before any swaps were submitted
    function _checkPermutations(SwapSpec[] memory specs, uint256[][] memory perms, uint256 baseSnap) private {
        uint256[] memory refOutputs = new uint256[](specs.length);
        uint160  refSqrtPrice;
        uint128  refLiquidity;

        for (uint256 p = 0; p < perms.length; p++) {
            (
                uint256[] memory outputs,
                uint160  sqrtPrice,
                uint128  liquidity,
                uint256  hb0,
                uint256  hb1
            ) = _runPermutation(specs, perms[p], baseSnap);

            // At most 1 wei of dust per trader due to floor rounding in distribution.
            assertLe(hb0, specs.length, "hook has excess token0 claims after clear");
            assertLe(hb1, specs.length, "hook has excess token1 claims after clear");

            if (p == 0) {
                for (uint256 i = 0; i < specs.length; i++) refOutputs[i] = outputs[i];
                refSqrtPrice = sqrtPrice;
                refLiquidity = liquidity;
                for (uint256 i = 0; i < specs.length; i++) {
                    assertGt(outputs[i], 0, "trader received no output");
                }
            } else {
                // Order-independence: pool state and each trader's output must match.
                assertEq(sqrtPrice, refSqrtPrice, "pool price differs across permutations");
                assertEq(liquidity, refLiquidity, "pool liquidity differs across permutations");
                for (uint256 i = 0; i < specs.length; i++) {
                    assertEq(outputs[i], refOutputs[i], "trader output differs across permutations");
                }
            }
        }

        // Fairness: same-direction traders must receive proportional output.
        for (uint256 i = 0; i < specs.length; i++) {
            for (uint256 j = i + 1; j < specs.length; j++) {
                if (specs[i].zeroForOne == specs[j].zeroForOne) {
                    _assertSameRate(
                        refOutputs[i], specs[i].amountIn,
                        refOutputs[j], specs[j].amountIn
                    );
                }
            }
        }
    }

    /// @notice exhaustively tests all 24 permutations of a 4-swap mixed-direction batch,
    ///         asserting order-independence and fairness after each clearing
    function test_orderIndependenceAndFairness() public {
        uint256 snapBefore = vm.snapshotState();

        SwapSpec[] memory specs = new SwapSpec[](4);
        specs[0] = SwapSpec({trader: address(0xA11CE), amountIn: 1e18,   zeroForOne: true});
        specs[1] = SwapSpec({trader: address(0xB0B),   amountIn: 0.5e18, zeroForOne: true});
        specs[2] = SwapSpec({trader: address(0xCAFE),  amountIn: 0.7e18, zeroForOne: false});
        specs[3] = SwapSpec({trader: address(0xD00D),  amountIn: 1.2e18, zeroForOne: false});

        // 4 swaps -> all 24 permutations are tested exhaustively.
        uint256[][] memory perms = _getPermutations(specs.length);
        assertEq(perms.length, 24);
        _checkPermutations(specs, perms, snapBefore);

        vm.revertToState(snapBefore);
    }

    /// @notice compares batch-clearing output against sequential AMM swaps for four traders
    ///         and asserts that the batch produces strictly greater total output for both sides
    /// @param amountToken0A input amount for currency0 trader A
    /// @param amountToken0B input amount for currency0 trader B
    /// @param amountToken1A input amount for currency1 trader A
    /// @param amountToken1B input amount for currency1 trader B
    function OutputBatVsSeq(uint256 amountToken0A, uint256 amountToken0B, uint256 amountToken1A, uint256 amountToken1B) internal {
        uint256 snapBefore = vm.snapshotState();
        address token0TraderA = address(0xA11DCE);
        address token0TraderB = address(0xBD0B);
        address token1TraderA = address(0xCACFE);
        address token1TraderB = address(0xDD00D);
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        vm.deal(token0TraderA, amountToken0A*2);
        vm.deal(token0TraderB, amountToken0B*2);
        token1.mint(token1TraderA, amountToken1A*2);
        token1.mint(token1TraderB, amountToken1B*2);
        vm.prank(token1TraderA);
        token1.approve(address(limitRouter), type(uint256).max);
        vm.prank(token1TraderB);
        token1.approve(address(limitRouter), type(uint256).max);
        vm.prank(token1TraderA);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.prank(token1TraderB);
        token1.approve(address(swapRouter), type(uint256).max);

        uint256 snap = vm.snapshotState();
        hook.allowRegularSwap();
        _swapWithLimit(token0TraderA, amountToken0A, true, TickMath.MIN_SQRT_PRICE + 1);
        _swapWithLimit(token0TraderB, amountToken0B, true, TickMath.MIN_SQRT_PRICE + 1);
        uint256 token1OutSeqA = currency1.balanceOf(token0TraderA);
        uint256 token1OutSeqB = currency1.balanceOf(token0TraderB);
        vm.revertToState(snap);

        hook.allowRegularSwap();
        _swapWithLimit(token1TraderA, amountToken1A, false, TickMath.MAX_SQRT_PRICE - 1);
        _swapWithLimit(token1TraderB, amountToken1B, false, TickMath.MAX_SQRT_PRICE - 1);
        uint256 token0OutSeqA = currency0.balanceOf(token1TraderA);
        uint256 token0OutSeqB = currency0.balanceOf(token1TraderB);
        vm.revertToState(snap);
        hook.disallowRegularSwap();

        _swapExactInput(token0TraderA, amountToken0A, true);
        _swapExactInput(token0TraderB, amountToken0B, true);
        _swapExactInput(token1TraderA, amountToken1A, false);
        _swapExactInput(token1TraderB, amountToken1B, false);
        assertTrue(hook.clearBatchNoInterval(key), "mixed-direction batch should clear");

        uint256 token0OutBatA = currency0.balanceOf(token1TraderA);
        uint256 token0OutBatB = currency0.balanceOf(token1TraderB);
        uint256 token1OutBatA = currency1.balanceOf(token0TraderA);
        uint256 token1OutBatB = currency1.balanceOf(token0TraderB);

        assertGt(token0OutBatA + token0OutBatB, token0OutSeqA + token0OutSeqB);
        assertGt(token1OutBatA + token1OutBatB, token1OutSeqA + token1OutSeqB);
        vm.revertToState(snapBefore);
    }

    /// @notice compares batch-clearing output against sequential AMM swaps for two traders
    ///         swapping in the same direction, so the batch has no opposing flow to net against;
    ///         the batch must do worse than sequential execution, but by no more than the
    ///         caller's compensation
    /// @param amountA input amount for trader A
    /// @param amountB input amount for trader B
    /// @param zeroForOne true if both traders swap currency0 for currency1
    function OutputBatVsSeqOneDirection(uint256 amountA, uint256 amountB, bool zeroForOne) internal {
        uint256 snapBefore = vm.snapshotState();
        address traderA = address(0xA11DCE);
        address traderB = address(0xBD0B);
        Currency output = zeroForOne ? currency1 : currency0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        hook.allowRegularSwap();
        _swapWithLimit(traderA, amountA, zeroForOne, limit);
        _swapWithLimit(traderB, amountB, zeroForOne, limit);
        uint256 outSeq = output.balanceOf(traderA) + output.balanceOf(traderB);
        vm.revertToState(snapBefore);

        // Set a known gas environment after the revert, which restores the block basefee.
        // gasPrice(15 gwei) < 2xbaseFee(20 gwei) so the basefee cap does not activate.
        vm.fee(10 gwei);
        vm.txGasPrice(15 gwei);

        _swapWithLimit(traderA, amountA, zeroForOne, limit);
        _swapWithLimit(traderB, amountB, zeroForOne, limit);
        assertTrue(hook.clearBatchNoInterval(key), "one-direction batch should clear");
        uint256 outBat = output.balanceOf(traderA) + output.balanceOf(traderB);

        // n=2, all on one side, so the whole rebate comes from the input token, capped at the
        // batch input.  At SQRT_PRICE_1_1 price=1 so its value in the output token is the same.
        uint256 n = 2;
        uint256 comp = (286049 + 42135 * n) * 15 gwei * 11 / 10;
        if (comp > amountA + amountB) comp = amountA + amountB;

        // the batch swaps amountA + amountB - comp in one pool swap, so traders receive less
        // than sequential execution, but the comp units would have been swapped last at a
        // worse-than-start price, so the shortfall is at most comp (plus pro-rata rounding)
        assertLt(outBat, outSeq, "one-direction batch should pay for caller compensation");
        assertLe(outSeq - outBat, comp + 2, "one-direction batch shortfall exceeds caller compensation");

        vm.revertToState(snapBefore);
        vm.txGasPrice(0);
    }

    /// @notice fuzz test that confirms the batch output guarantee holds across random input amounts;
    ///         amounts are re-derived each iteration via modulo to avoid bound() overhead
    function test_outputGuar(
        uint256 amountToken0A,
        uint256 amountToken0B,
        uint256 amountToken1A,
        uint256 amountToken1B
    ) public {
        for (uint256 y = 0; y < 20; y++) {
            amountToken0A = 1e11 + amountToken0A % (2e19 - 1e11);
            amountToken0B = 1e11 + amountToken0B % (2e19 - 1e11);
            amountToken1A = 1e11 + amountToken1A % (2e19 - 1e11);
            amountToken1B = 1e11 + amountToken1B % (2e19 - 1e11);
            OutputBatVsSeq(amountToken0A, amountToken0B, amountToken1A, amountToken1B);
            OutputBatVsSeqOneDirection(amountToken0A, amountToken0B, true);
            OutputBatVsSeqOneDirection(amountToken1A, amountToken1B, false);
        }
    }

    /// @notice logs the gas cost of a single async swap and a regular AMM swap for comparison
    function test_gasForSwap() public {
        int256 amountSpecified = -1e18;
        bool zeroForOne = true;

        uint256 g = gasleft();
        swapRouter.swap{value: uint256(-amountSpecified)}({
            amountSpecified: amountSpecified,
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 manual = g - gasleft();
        console.log("asyncSwap ", manual);

        hook.allowRegularSwap();
        g = gasleft();
        swapRouter.swap{value: uint256(-amountSpecified)}({
            amountSpecified: amountSpecified,
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        manual = g - gasleft();
        hook.disallowRegularSwap();
        console.log("regularSwap ", manual);
    }

    /// @notice submits k swaps with random directions and amounts derived from seed,
    ///         each capped at 5e16 to stay within pool reserves even at k=128
    /// @param k number of swaps to submit
    /// @param seed entropy source used to derive per-swap direction and amount
    function _submitKSwaps(uint256 k, uint256 seed) internal {
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        for (uint256 j = 0; j < k; j++) {
            address trader = address(uint160(uint256(keccak256(abi.encode("trader", j)))));
            // derive direction and amount independently from the seed + index
            uint256 rand = uint256(keccak256(abi.encode(seed, j)));
            bool zeroForOne = rand % 2 == 0;
            // cap at 5e16 so even k=128 all-same-direction stays within pool reserves
            uint256 amountIn = 1e14 + (rand >> 1) % (5e16 - 1e14);

            if (zeroForOne) {
                vm.deal(trader, amountIn);
            } else {
                deal(address(token1), trader, amountIn);
                vm.prank(trader);
                token1.approve(address(swapRouter), type(uint256).max);
            }

            _swapExactInput(trader, amountIn, zeroForOne);
        }
    }

    /// @notice measures and logs total gas and gas-per-trade for clearBatchNoInterval
    ///         across batch sizes [1, 2, 4, 8, 16, 32, 64, 128] using a random seed
    /// forge-config: default.fuzz.runs = 32
    function test_gasForClearing(uint256 seed) public {
        uint256[8] memory ks = [uint256(1), 2, 4, 8, 16, 32, 64, 128];
        for (uint256 n = 0; n < ks.length; n++) {
            uint256 k = ks[n];
            uint256 snap = vm.snapshotState();

            _submitKSwaps(k, seed);

            uint256 g = gasleft();
            bool ok = hook.clearBatchNoInterval(key);
            uint256 manual = g - gasleft();

            if (ok) console.log(k, manual, manual / k);
            vm.revertToState(snap);
        }
    }
}
