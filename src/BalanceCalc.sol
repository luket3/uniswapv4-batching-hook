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

/**
 * @title BalanceCalc
 * @author luket3
 * @notice Read-only calculator, computes the trade required to Balance a batch for clearing
 */
library BalanceCalc {
	using PoolIdLibrary for PoolKey;
	using StateLibrary for IPoolManager;
	using SafeCast for uint256;
	using SafeCast for int256;
	using ProtocolFeeLibrary for uint16;
	using ProtocolFeeLibrary for uint24;

	/// @dev simulation state, may change during execution
	struct SimulationState {
		uint160 sqrtPriceX96; // Simulated price at the current step.
		int24 tick; // Tick used to locate the next initialized tick.
		uint128 liquidity; // Active liquidity for the current tick range.
		uint256 amountRemaining0; // Unspent token0
		uint256 amountRemaining1; // Unspent token1
	}

	/// @dev simulation configuration, remains constant after initalised
	struct SimulationConfig {
		PoolId poolId; // ID of pool to simulate on
		int24 tickSpacing; // tick spacing in pool to simulate on
		uint24 swapFeeZeroForOne; // swap fee for trading zeroForOne
		uint24 swapFeeOneForZero; // swap fee for trading OneForZero
		uint160 sqrtPriceUpperX96; // upper price limit
		uint160 sqrtPriceLowerX96; // lower price limit
	}

	/// @notice amountIn exceeds maximum valid amount
	error AmountTooLarge();

	/// @notice given upper or lower price limit in invalid
	error InvalidSqrtPriceLimit();

	/// @notice given upper or lower price limit is exceeded by calculated trade
	error PriceLimitExceeded();

	/// @notice maximum swap fee
	uint256 internal constant MAX_SWAP_FEE = 1e6;

	/**
	 * @notice converts a compressed tick into its bitmap word and bit indexes
	 * @param compressed the compressed tick value
	 * @return wordPos the word position in the tick bitmap array
	 * @return bitPos the bit position within the word
	 */
	function _bitmapPosition(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
		wordPos = int16(compressed >> 8);
		bitPos = uint8(uint24(compressed) & 0xff);
	}

	/**
	 * @notice finds the next initialized tick in the bitmap word containing the current tick
	 * @param poolManager the pool manager storing the tick bitmap
	 * @param poolId the pool to inspect
	 * @param tick the current tick used as the starting point
	 * @param tickSpacing the pool tick spacing
	 * @param lte whether to search backwards through the current word or forwards
	 * @return nextTick the next initialized tick found in the traversal direction
	 * @return initialized whether the next tick in range is initialized
	 * @dev matches v4's one-word tick traversal behavior when scanning the tick bitmap
	 */
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

	/**
	 * @notice returns the next initialized tick and price for the direction implied by the balancing trade
	 * @param poolManager the pool manager used to query the tick bitmap
	 * @param config the simulation parameters for this path
	 * @param tick the current tick from the simulation state
	 * @param zeroForOne the direction to inspect
	 * @return sqrtPriceNextX96 the price at the next initialized tick boundary
	 * @return tickNext the next initialized tick in that direction
	 * @return initialized whether the returned tick is initialized
	 */
	function _getNextInitializedTickForDirection(
		IPoolManager poolManager,
		SimulationConfig memory config,
		int24 tick,
		bool zeroForOne
	) private view returns (uint160 sqrtPriceNextX96, int24 tickNext, bool initialized) {
		(tickNext, initialized) = _nextInitializedTickWithinOneWord(
			poolManager,
			config.poolId,
			tick,
			config.tickSpacing,
			zeroForOne
		);
		if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
		if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;
		sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);
	}

	/**
	 * @notice computes the amount required to move to either to tick boundary or balance the tokens
	 * @param poolManager the pool manager used to resolve next tick data
	 * @param config the simulation configuration for the current pool
	 * @param state the current simualtion state
	 * @param amountToken0 amount of token0 remaining
	 * @param amountToken1 amount of token1 remaining
	 * @param sqrtPriceCurrentX96 the current price the simulation sits at
	 * @param liquidity the liquidity in the active tick
	 * @param zfoFeePips the feePips trading zeroForOne
	 * @param ofzFeePips the feePips trading oneForZero
	 * @return sqrtPriceTargetX96 the sqrtPriceX96 after the trade executes
	 * @return amountIn the amount consumed during the trade
	 * @return consumedAll if the trade consumed all tokens required to balance
	 * @return zeroForOne the direction of the trade
	 * @return sqrtPriceNextX96 the price at the next valid tick boundary in the chosen direction
	 * @return tickNext the next tick boundary in the chosen direction
	 * @return initialized whether the next tick boundary is initialized
	 * @dev a trade is considered balanced if the amount remaining of each token is equivilent after
	 *      the trade
	 */
	function _getAmountToTarget(
		IPoolManager poolManager,
		SimulationConfig memory config,
		SimulationState memory state,
		uint256 amountToken0,
		uint256 amountToken1,
		uint160 sqrtPriceCurrentX96,
		uint128 liquidity,
		uint24 zfoFeePips,
		uint24 ofzFeePips
	) internal view returns (
		uint160 sqrtPriceTargetX96,
		uint256 amountIn,
		bool consumedAll,
		bool zeroForOne,
		uint160 sqrtPriceNextX96,
		int24 tickNext,
		bool initialized
	) {
		// calculate amount to trade after fees
		uint256 _zfoFeePips = zfoFeePips;
		uint256 _ofzFeePips = ofzFeePips;
		uint256 amountToken0LessFee = FullMath.mulDiv(amountToken0, MAX_SWAP_FEE - _zfoFeePips, MAX_SWAP_FEE);
		uint256 amountToken1LessFee = FullMath.mulDiv(amountToken1, MAX_SWAP_FEE - _ofzFeePips, MAX_SWAP_FEE);

		// find the price after executing all remaining tokens
		// moving to this price means remaining tokens will be equivilent
		uint160 sqrtPriceAfter0X96 = SqrtPriceMath.getNextSqrtPriceFromInput(
			sqrtPriceCurrentX96, liquidity, amountToken0LessFee, true
		);
		uint160 sqrtPriceAfter1X96 = SqrtPriceMath.getNextSqrtPriceFromInput(
			sqrtPriceAfter0X96, liquidity, amountToken1LessFee, false
		);
		
		// see if trade is capped at tick
		zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceAfter1X96;
		(sqrtPriceNextX96, tickNext, initialized) = _getNextInitializedTickForDirection(
			poolManager,
			config,
			state.tick,
			zeroForOne
		);
		sqrtPriceTargetX96 = SwapMath.getSqrtPriceTarget(
			zeroForOne,
			sqrtPriceNextX96,
			sqrtPriceAfter1X96
		);
		
		// caculate if balancing trade was found and amount required to reach sqrtPriceTargetX96 including fee's
		consumedAll = sqrtPriceTargetX96 == sqrtPriceAfter1X96;
		if (zeroForOne) {
			amountIn = SqrtPriceMath.getAmount0Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true);
			amountIn += FullMath.mulDivRoundingUp(amountIn, _zfoFeePips, MAX_SWAP_FEE - _zfoFeePips);
		} else {
			amountIn = SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true);
			amountIn += FullMath.mulDivRoundingUp(amountIn, _ofzFeePips, MAX_SWAP_FEE - _ofzFeePips);
		}
	}

	/**
	 * @notice step through one tick and check if balancing trade exists in liquidity range
	 * @param poolManager the pool manager to run simulation on
	 * @param config configuration of simuation
	 * @param state state of simulation
	 * @return tradeFound if a balancing trade was found
	 */
	function _stepAmountToBalanceMath(
		IPoolManager poolManager,
		SimulationConfig memory config,
		SimulationState memory state
	) private view returns(bool tradeFound) {
		uint160 sqrtPriceStartX96 = state.sqrtPriceX96;
		(
			uint160 newStatePrice,
			uint256 amountIn,
			bool consumedAll,
			bool zeroForOne,
			uint160 sqrtPriceNextX96,
			int24 tickNext,
			bool initialized
		) = _getAmountToTarget(
			poolManager,
			config,
			state,
			state.amountRemaining0,
			state.amountRemaining1,
			state.sqrtPriceX96,
			state.liquidity,
			config.swapFeeZeroForOne,
			config.swapFeeOneForZero
		);
		state.sqrtPriceX96 = newStatePrice;

		// update state
		if (zeroForOne) {
			state.amountRemaining0 -= amountIn;
		} else {
			state.amountRemaining1 -= amountIn;
		}

		// compute tick movement
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

	/**
	 * @notice Reads the state needed for swap math
	 * @param poolManager the poolManger to simulate on
	 * @param poolId the pool to simulate on
	 * @param amountIn0 the amount of token0 held by batch
	 * @param amountIn1 the amount of token1 held by batch
	 * @return state the state variable to record information onto
	 * @return protocolFee the protocol fee used to calculate swapfee
	 * @return lpFee the lp fee used to calculate swapfee
	 */
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

	/**
	 * @notice loads current pool state and steps through ticks until a result is found
	 * @param poolManager the pool manager used for the simulation
	 * @param key the key of the pool used in the calculation
	 * @param amountIn0 amount of held token0 in batch
	 * @param amountIn1 amount of held token1 in batch
	 * @param sqrtPriceUpperX96 upper price limit for simulation
	 * @param sqrtPriceLowerX96 lower price limit for simulation
	 * @return amount the amount to trade to balance held tokens
	 * @return zeroForOne the direction to trade to balance held tokens
	 */
	function _AmountToBalanceMath(
		IPoolManager poolManager,
		PoolKey memory key,
		uint256 amountIn0,
		uint256 amountIn1,
		uint160 sqrtPriceUpperX96,
		uint160 sqrtPriceLowerX96
	) private view returns (uint256 amount, bool zeroForOne) {

		// check given arguments are valid
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

		// initalise config for simulation
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

		// step through ticks until trade is found or price limit is exceeded
		bool consumedAll = false;
		while (!consumedAll) {
			consumedAll = _stepAmountToBalanceMath(poolManager, config, state);
			if ((state.sqrtPriceX96 <= sqrtPriceLowerX96 || state.sqrtPriceX96 >= sqrtPriceUpperX96) && !consumedAll) {
				revert PriceLimitExceeded();
			}
		}

		// return calculated trade
		if (state.amountRemaining0 < amountIn0) {
			return (amountIn0 - state.amountRemaining0, true);
		} else {
			return (amountIn1 - state.amountRemaining1, false);
		}
	}

	/**
	 * @notice calculates trade to balance amountIn0 and amountIn1 for batch clearing
	 * @param poolManager the pool manager used for the simulation
	 * @param key the key of the pool used in the calculation
	 * @param amountIn0 amount of held token0 in batch
	 * @param amountIn1 amount of held token1 in batch
	 * @param sqrtPriceUpperX96 upper price limit for simulation
	 * @param sqrtPriceLowerX96 lower price limit for simulation
	 * @return amount the amount to trade to balance held tokens
	 * @return zeroForOne the direction to trade to balance held tokens
	 * @dev if upper or lower price limit is passed reverts as priceLimitExceeded
	 */
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
}
