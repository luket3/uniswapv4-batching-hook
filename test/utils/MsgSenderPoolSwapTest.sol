// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

/// @notice A drop-in replacement for PoolSwapTest that implements IMsgSender so that
///         hooks can recover the original caller via IMsgSender(sender).msgSender()
///         rather than relying on hookData encoding.
contract MsgSenderPoolSwapTest is IUnlockCallback, IMsgSender {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    /// @dev stored at the start of swap() and cleared on return; valid during the unlock callback
    address private _msgSenderStored;

    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    struct CallbackData {
        address sender;
        TestSettings testSettings;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @inheritdoc IMsgSender
    function msgSender() external view override returns (address) {
        return _msgSenderStored;
    }

    /// @notice submits a swap via the pool manager, storing the caller so hooks can
    ///         recover it through IMsgSender.msgSender()
    function swap(
        PoolKey memory key,
        SwapParams memory params,
        TestSettings memory testSettings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        _msgSenderStored = msg.sender;
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, testSettings, key, params, hookData))),
            (BalanceDelta)
        );
        _msgSenderStored = address(0);
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(manager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (,, int256 deltaBefore0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaBefore1) = _fetchBalances(data.key.currency1, data.sender, address(this));
        require(deltaBefore0 == 0, "deltaBefore0 is not equal to 0");
        require(deltaBefore1 == 0, "deltaBefore1 is not equal to 0");

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        (,, int256 deltaAfter0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if (deltaAfter0 < 0) {
            data.key.currency0.settle(manager, data.sender, uint256(-deltaAfter0), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter1 < 0) {
            data.key.currency1.settle(manager, data.sender, uint256(-deltaAfter1), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter0 > 0) {
            data.key.currency0.take(manager, data.sender, uint256(deltaAfter0), data.testSettings.takeClaims);
        }
        if (deltaAfter1 > 0) {
            data.key.currency1.take(manager, data.sender, uint256(deltaAfter1), data.testSettings.takeClaims);
        }

        return abi.encode(delta);
    }

    function _fetchBalances(Currency currency, address user, address deltaHolder)
        internal
        view
        returns (uint256 userBalance, uint256 poolBalance, int256 delta)
    {
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(manager));
        delta = manager.currencyDelta(deltaHolder, currency);
    }

    receive() external payable {}
}
