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
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {console} from "forge-std/console.sol";

/// @notice Read-only exact-input swap simulation using the pool's current v4 state.
/// @dev Mirrors Pool.swap's tick traversal without writing pool state or invoking hooks.
library BalanceCalc {
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
		uint256 amountRemaining0; // Unspent exact-input amount, including fees.
		uint256 amountRemaining1; // Unspent exact-input amount, including fees.
		int256 amountCalculated; // Output accumulated across tick ranges.
	}

	struct SimulationConfig {
		PoolId poolId;
		int24 tickSpacing;
		uint24 swapFeeZeroForOne;
		uint24 swapFeeOneForZero;
		uint160 sqrtPriceUpperX96;
		uint160 sqrtPriceLowerX96;
	}

	error AmountTooLarge();
	error InvalidSqrtPriceLimit();
	error PriceLimitExceeded();

	uint256 internal constant MAX_SWAP_FEE = 1e6;

	/// @notice Simulates an exact-input swap and returns deltas from the caller's perspective.
	/// @dev Positive deltas are received by the caller; negative deltas are paid by the caller.
	function getAmountToBalance(
		IPoolManager poolManager,
		PoolKey memory key,
		uint256 amountIn0,
		uint256 amountIn1,
		uint160 sqrtPriceUpperX96,
		uint160 sqrtPriceLowerX96
	) internal view returns (uint256 amount, bool zeroForOne) {
		(amount, zeroForOne) = _AmountToBalanceMath(
			poolManager,
			key,
			amountIn0,
			amountIn1,
			sqrtPriceUpperX96,
			sqrtPriceLowerX96
		);
	}

	// Loads current pool state and simulates until the input is spent or the price limit is hit.
	function _AmountToBalanceMath(
		IPoolManager poolManager,
		PoolKey memory key,
		uint256 amountIn0,
		uint256 amountIn1,
		uint160 sqrtPriceUpperX96,
		uint160 sqrtPriceLowerX96
	) private view returns (uint256 amount, bool zeroForOne) {
		if (amountIn0 > uint256(type(int256).max) || amountIn1 > uint256(type(int256).max)) revert AmountTooLarge();

		PoolId poolId = key.toId();
		(SimulationState memory state, uint24 protocolFeePacked, uint24 lpFee) =
			_loadState(poolManager, poolId, amountIn0, amountIn1);
		if (amountIn0 == 0 && amountIn1 == 0) return (0, false);

		if (sqrtPriceLowerX96 > state.sqrtPriceX96 || 
			sqrtPriceLowerX96 < TickMath.MIN_SQRT_PRICE
		) {
			revert InvalidSqrtPriceLimit();
		}
		if (sqrtPriceUpperX96 < state.sqrtPriceX96 ||
			sqrtPriceUpperX96 > TickMath.MAX_SQRT_PRICE
		) {
			revert InvalidSqrtPriceLimit();
		}

		uint16 zeroForOneProtocolFee = protocolFeePacked.getZeroForOneFee();
		uint16 oneForZeroProtocolFee = protocolFeePacked.getOneForZeroFee();
		uint24 swapFeeZeroForOne = zeroForOneProtocolFee == 0
			? lpFee
			: zeroForOneProtocolFee.calculateSwapFee(lpFee);
		uint24 swapFeeOneForZero = oneForZeroProtocolFee == 0
			? lpFee
			: oneForZeroProtocolFee.calculateSwapFee(lpFee);

		SimulationConfig memory config = SimulationConfig({
			poolId: poolId,
			tickSpacing: key.tickSpacing,
			swapFeeZeroForOne: swapFeeZeroForOne,
			swapFeeOneForZero: swapFeeOneForZero,
			sqrtPriceUpperX96: sqrtPriceUpperX96,
			sqrtPriceLowerX96: sqrtPriceLowerX96
		});

		bool consumedAll = false;
		while (!consumedAll) {
			consumedAll = _stepAmountToBalanceMath(poolManager, config, state);
			if ((state.sqrtPriceX96 <= sqrtPriceLowerX96 || state.sqrtPriceX96 >= sqrtPriceUpperX96) && !consumedAll) {
				revert PriceLimitExceeded();
			}
		}

		if (state.amountRemaining0 < amountIn0) {
			return (amountIn0 - state.amountRemaining0, true);
		} else {
			return (amountIn1 - state.amountRemaining1, false);
		}
	}

	// Simulates one tick-range step, then applies the liquidity change if an initialized tick was crossed.
	function _stepAmountToBalanceMath(
		IPoolManager poolManager,
		SimulationConfig memory config,
		SimulationState memory state
	) private view returns(bool) {
		(int24 zfoTickNext, bool zfoInitialized) = _nextInitializedTickWithinOneWord(
			poolManager,
			config.poolId,
			state.tick,
			config.tickSpacing,
			true
		);
		(int24 ofzTickNext, bool ofzInitialized) = _nextInitializedTickWithinOneWord(
			poolManager,
			config.poolId,
			state.tick,
			config.tickSpacing,
			false
		);

		if (zfoTickNext <= TickMath.MIN_TICK) zfoTickNext = TickMath.MIN_TICK;
		if (zfoTickNext >= TickMath.MAX_TICK) zfoTickNext = TickMath.MAX_TICK;
		if (ofzTickNext <= TickMath.MIN_TICK) ofzTickNext = TickMath.MIN_TICK;
		if (ofzTickNext >= TickMath.MAX_TICK) ofzTickNext = TickMath.MAX_TICK;

		uint160 zfoSqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(zfoTickNext);
		uint160 ofzSqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(ofzTickNext);
		(uint160 newStatePrice, uint256 amountToTarget, bool consumedAll, bool zeroForOne) = _getAmountToTarget(
			state.amountRemaining0,
			state.amountRemaining1,
			state.sqrtPriceX96,
			zfoSqrtPriceNextX96,
			ofzSqrtPriceNextX96,
			state.liquidity,
			config.swapFeeZeroForOne,
			config.swapFeeOneForZero
		);
		uint160 sqrtPriceStartX96 = state.sqrtPriceX96;
		state.sqrtPriceX96 = newStatePrice;

		uint160 sqrtPriceNextX96;
		bool initialized;
		int24 tickNext;
		if (zeroForOne) {
			sqrtPriceNextX96 = zfoSqrtPriceNextX96;
			initialized = zfoInitialized;
			tickNext = zfoTickNext;
		} else {
			sqrtPriceNextX96 = ofzSqrtPriceNextX96;
			initialized = ofzInitialized;
			tickNext = ofzTickNext;
		}

		zeroForOne 
			? state.amountRemaining0 -= amountToTarget
			: state.amountRemaining1 -= amountToTarget;

		if (state.sqrtPriceX96 == sqrtPriceNextX96) {
			if (initialized) {
				(, int128 liquidityNet) = poolManager.getTickLiquidity(config.poolId, tickNext);
				if (zeroForOne) liquidityNet = -liquidityNet;
				state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
			}
			state.tick = zeroForOne ? tickNext - 1 : tickNext;
		} else if (state.sqrtPriceX96 != sqrtPriceStartX96) {
			state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
		}

		return consumedAll;
	}

	function _getAmountToTarget(
		uint256 amountToken0,
		uint256 amountToken1,
		uint160 sqrtPriceCurrentX96,
		uint160 zfoSqrtPriceNextX96,
		uint160 ofzSqrtPriceNextX96,
		uint128 liquidity,
		uint24 zfoFeePips,
		uint24 ofzFeePips
	) internal pure returns (uint160 sqrtPriceTargetX96, uint256 amountToTarget, bool consumedAll, bool zeroForOne) {
		uint256 _zfoFeePips = zfoFeePips;
		uint256 _ofzFeePips = ofzFeePips;

		uint256 amountToken0LessFee = FullMath.mulDiv(amountToken0, MAX_SWAP_FEE - _zfoFeePips, MAX_SWAP_FEE);
		uint256 amountToken1LessFee = FullMath.mulDiv(amountToken1, MAX_SWAP_FEE - _ofzFeePips, MAX_SWAP_FEE);

		uint160 sqrtPriceAfter0X96 = SqrtPriceMath.getNextSqrtPriceFromInput(
			sqrtPriceCurrentX96, liquidity, amountToken0LessFee, true
		);
		uint160 sqrtPriceAfter1X96 = SqrtPriceMath.getNextSqrtPriceFromInput(
			sqrtPriceAfter0X96, liquidity, amountToken1LessFee, false
		);
		
		zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceAfter1X96;
		uint160 sqrtPriceNextX96;
		zeroForOne
			? sqrtPriceNextX96 = zfoSqrtPriceNextX96
			: sqrtPriceNextX96 = ofzSqrtPriceNextX96;

		sqrtPriceTargetX96 = SwapMath.getSqrtPriceTarget(
			zeroForOne,
			sqrtPriceNextX96,
			sqrtPriceAfter1X96
		);
		
		consumedAll = sqrtPriceTargetX96 == sqrtPriceAfter1X96;
		amountToTarget = zeroForOne
			? SqrtPriceMath.getAmount0Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true)
			: SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true);

		amountToTarget = zeroForOne
			? amountToTarget + FullMath.mulDivRoundingUp(amountToTarget, _zfoFeePips, MAX_SWAP_FEE - _zfoFeePips)
			: amountToTarget + FullMath.mulDivRoundingUp(amountToTarget, _ofzFeePips, MAX_SWAP_FEE - _ofzFeePips);
	}

	// Reads only the state needed for swap math; no pool storage is modified.
	function _loadState(IPoolManager poolManager, PoolId poolId, uint256 amountIn0, uint256 amountIn1)
		private
		view
		returns (SimulationState memory state, uint24 protocolFee, uint24 lpFee)
	{
		(state.sqrtPriceX96, state.tick, protocolFee, lpFee) = poolManager.getSlot0(poolId);
		state.liquidity = poolManager.getLiquidity(poolId);
		state.amountRemaining0 = amountIn0;
		state.amountRemaining1 = amountIn1;
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
