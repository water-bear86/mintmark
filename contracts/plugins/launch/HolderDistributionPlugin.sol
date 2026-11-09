// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMintMarkFeePlugin} from "../../interfaces/IMintMarkFeePlugin.sol";
import {ILaunchTokenExtensions} from "../../interfaces/ILaunchTokenExtensions.sol";
import {ILaunchFeePlugin} from "../../interfaces/plugins/ILaunchFeePlugin.sol";
import {IHolderDistributionPlugin} from "../../interfaces/plugins/IHolderDistributionPlugin.sol";
import {LaunchFeePluginBase} from "./LaunchFeePluginBase.sol";

/// @title HolderDistributionPlugin
/// @notice Pays each launch token's creator fees to that token's holders through the token's built-in ETH dividends.
///         Each delivery goes straight to the token's distribute, which streams it to the eligible holders over
///         24 hours with continuous accrual, so a holder earns only for the time it holds. Holders claim on the token.
/// @dev A forwarder: onFees passes the exact ETH it received straight into the token's distribute, all in one call,
///      so this plugin holds nothing between calls. The token's distribute never reverts for lack of eligible
///      supply, so nothing holder-side can make onFees revert (behind a Combo, that would block the token's
///      collections).
contract HolderDistributionPlugin is IHolderDistributionPlugin, LaunchFeePluginBase {
    mapping(address token => uint256) private _distributed;

    constructor(address launchpad_) LaunchFeePluginBase(launchpad_) {}

    // ─── Hooks ────────────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkFeePlugin
    /// @dev Takes no configuration: `data` must be empty.
    function onLaunch(address token, address creator, bytes calldata data) external nonReentrant {
        if (data.length != 0) revert DataNotEmpty();
        _configure(token, creator);
    }

    /// @inheritdoc IMintMarkFeePlugin
    /// @dev Forwards exactly the ETH this call carries into the token's dividend stream. Zero is a no-op.
    function onFees(address token, uint256 amount) external payable nonReentrant {
        _requireConfigured(token);
        _requireExactValue(amount);
        if (amount == 0) return;
        emit FeesReceived(token, msg.sender, amount);
        _distributed[token] += amount;
        emit Distributed(token, amount);
        ILaunchTokenExtensions(token).distribute{value: amount}();
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IHolderDistributionPlugin
    function totalDistributed(address token) external view returns (uint256) {
        return _distributed[token];
    }

    /// @inheritdoc ILaunchFeePlugin
    /// @dev Always zero: onFees passes everything it receives to the token in the same call.
    function ethHeld(address) external pure returns (uint256) {
        return 0;
    }
}
