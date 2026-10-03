// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Read-only exact-input swap simulation using the pool's current v4 state.
/// @dev Mirrors Pool.swap's tick traversal without writing pool state or invoking hooks.
library SwapSim {
	using PoolIdLibrary for PoolKey;
	using StateLibrary for IPoolManager;
	using SafeCast for uint256;
	using SafeCast for int256;
	using ProtocolFeeLibrary for uint16;
	using ProtocolFeeLibrary for uint24;

	struct SimulationState {
		uint160 sqrtPriceX96; // Simulated price at the current step.
		int24 tick; // Tick used to locate the next initialized tick.
		uint128 liquidity; // Active liquidity for the current tick range.
		int256 amountSpecifiedRemaining; // Unspent exact-input amount, including fees.
		int256 amountCalculated; // Output accumulated across tick ranges.
	}

	struct SimulationConfig {
		PoolId poolId;
		int24 tickSpacing;
		bool zeroForOne;
		uint24 swapFee;
		uint160 sqrtPriceLimitX96;
	}

	error AmountTooLarge();
	error InvalidSqrtPriceLimit();
	error PriceLimitExceeded();

	/// @notice Simulates an exact-input swap and returns deltas from the caller's perspective.
	/// @dev Positive deltas are received by the caller; negative deltas are paid by the caller.
	function simulateSwap(
		IPoolManager poolManager,
		PoolKey memory key,
		bool zeroForOne,
		uint256 amountIn,
		uint160 sqrtPriceLimitX96
	) internal view returns (int128 amount0Delta, int128 amount1Delta, uint160 sqrtPriceAfterX96) {
		(BalanceDelta delta, uint160 sqrtPriceAfter) = _simulateSwapMath(
			poolManager,
			key,
			zeroForOne,
			amountIn,
			sqrtPriceLimitX96
		);
		return (
			BalanceDeltaLibrary.amount0(delta),
			BalanceDeltaLibrary.amount1(delta),
			sqrtPriceAfter
		);
	}

	// Loads the current pool state and repeatedly simulates steps until input is spent or the price limit is hit.
	function _simulateSwapMath(
		IPoolManager poolManager,
		PoolKey memory key,
		bool zeroForOne,
		uint256 amountIn,
		uint160 sqrtPriceLimitX96
	) private view returns (BalanceDelta swapDelta, uint160 sqrtPriceAfterX96) {
		if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();

		PoolId poolId = key.toId();
		(SimulationState memory state, uint24 protocolFeePacked, uint24 lpFee) =
			_loadState(poolManager, poolId, amountIn);
		sqrtPriceAfterX96 = state.sqrtPriceX96;
		if (amountIn == 0) return (BalanceDelta.wrap(0), sqrtPriceAfterX96);

		if (zeroForOne) {
			if (
				sqrtPriceLimitX96 >= state.sqrtPriceX96
					|| sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE
			) revert InvalidSqrtPriceLimit();
		} else if (
			sqrtPriceLimitX96 <= state.sqrtPriceX96
				|| sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE
		) {
			revert InvalidSqrtPriceLimit();
		}

		uint16 directionalProtocolFee = zeroForOne
			? protocolFeePacked.getZeroForOneFee()
			: protocolFeePacked.getOneForZeroFee();
		uint24 swapFee = directionalProtocolFee == 0
			? lpFee
			: directionalProtocolFee.calculateSwapFee(lpFee);
		int256 amountSpecified = -int256(amountIn);
		state.amountSpecifiedRemaining = amountSpecified;
		SimulationConfig memory config = SimulationConfig({
			poolId: poolId,
			tickSpacing: key.tickSpacing,
			zeroForOne: zeroForOne,
			swapFee: swapFee,
			sqrtPriceLimitX96: sqrtPriceLimitX96
		});

		while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
			_stepSwapMath(poolManager, config, state);
			if (state.sqrtPriceX96 == sqrtPriceLimitX96 && state.amountSpecifiedRemaining != 0) {
				revert PriceLimitExceeded();
			}
		}

		int128 inputDelta = (amountSpecified - state.amountSpecifiedRemaining).toInt128();
		int128 outputDelta = state.amountCalculated.toInt128();
		swapDelta = zeroForOne
			? toBalanceDelta(inputDelta, outputDelta)
			: toBalanceDelta(outputDelta, inputDelta);
		sqrtPriceAfterX96 = state.sqrtPriceX96;
	}

	// Simulates one tick-range step, then applies the liquidity change if an initialized tick was crossed.
	function _stepSwapMath(
		IPoolManager poolManager,
		SimulationConfig memory config,
		SimulationState memory state
	) private view {
		(int24 tickNext, bool initialized) = _nextInitializedTickWithinOneWord(
			poolManager,
			config.poolId,
			state.tick,
			config.tickSpacing,
			config.zeroForOne
		);
		if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
		if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;

		uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);
		uint160 sqrtPriceTargetX96 = SwapMath.getSqrtPriceTarget(
			config.zeroForOne,
			sqrtPriceNextX96,
			config.sqrtPriceLimitX96
		);
		uint160 sqrtPriceStartX96 = state.sqrtPriceX96;
		uint256 amountInStep;
		uint256 amountOutStep;
		uint256 feeAmount;
		(state.sqrtPriceX96, amountInStep, amountOutStep, feeAmount) = SwapMath.computeSwapStep(
			state.sqrtPriceX96,
			sqrtPriceTargetX96,
			state.liquidity,
			state.amountSpecifiedRemaining,
			config.swapFee
		);

		state.amountSpecifiedRemaining += amountInStep.toInt256() + feeAmount.toInt256();
		state.amountCalculated += amountOutStep.toInt256();

		if (state.sqrtPriceX96 == sqrtPriceNextX96) {
			if (initialized) {
				(, int128 liquidityNet) = poolManager.getTickLiquidity(config.poolId, tickNext);
				if (config.zeroForOne) liquidityNet = -liquidityNet;
				state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
			}
			state.tick = config.zeroForOne ? tickNext - 1 : tickNext;
		} else if (state.sqrtPriceX96 != sqrtPriceStartX96) {
			state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
		}
	}

	// Reads only the state needed for swap math; no pool storage is modified.
	function _loadState(IPoolManager poolManager, PoolId poolId, uint256 amountIn)
		private
		view
		returns (SimulationState memory state, uint24 protocolFee, uint24 lpFee)
	{
		(state.sqrtPriceX96, state.tick, protocolFee, lpFee) = poolManager.getSlot0(poolId);
		state.liquidity = poolManager.getLiquidity(poolId);
		state.amountSpecifiedRemaining = -int256(amountIn);
	}

	// Searches the bitmap word containing the current tick, matching v4's one-word tick traversal.
	function _nextInitializedTickWithinOneWord(
		IPoolManager poolManager,
		PoolId poolId,
		int24 tick,
		int24 tickSpacing,
		bool lte
	) private view returns (int24 nextTick, bool initialized) {
		int24 compressed = tick / tickSpacing;
		if (tick < 0 && tick % tickSpacing != 0) compressed--;

		int16 wordPos;
		uint8 bitPos;
		if (lte) {
			(wordPos, bitPos) = _bitmapPosition(compressed);
			uint256 mask = type(uint256).max >> (type(uint8).max - bitPos);
			uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;
			initialized = masked != 0;
			nextTick = initialized
				? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
				: (compressed - int24(uint24(bitPos))) * tickSpacing;
		} else {
			compressed++;
			(wordPos, bitPos) = _bitmapPosition(compressed);
			uint256 bitmap = poolManager.getTickBitmap(poolId, wordPos);
			uint256 mask = ~((uint256(1) << bitPos) - 1);
			uint256 masked = bitmap & mask;
			initialized = masked != 0;
			nextTick = initialized
				? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
				: (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
		}
	}

	// Converts a compressed tick into its bitmap word and bit indexes.
	function _bitmapPosition(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
		wordPos = int16(compressed >> 8);
		bitPos = uint8(uint24(compressed) & 0xff);
	}
}
