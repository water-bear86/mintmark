// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMintMarkFeePlugin} from "../IMintMarkFeePlugin.sol";

/// @title What every MintMark reference creator-fee plugin exposes (docs/PLUGIN-MARKETPLACE-SPEC.md §D4, §D6).
/// @notice The reference plugins are singletons: one deployment serves every launch token that picks it, and
///         configuration and ETH are accounted per token. A token is configured once, by the launchpad inside
///         createToken or by the token's registered plugin (a Combo), and the configuration never changes.
///         Fees arrive through onFees, which requires its credit to equal the ETH the call carries.
interface ILaunchFeePlugin is IMintMarkFeePlugin {
    /// @notice `token` was configured for this plugin. `creator` is as passed by the configuring caller.
    event Configured(address indexed token, address indexed creator);
    /// @notice `amount` wei arrived from `from` and was credited to `token`.
    event FeesReceived(address indexed token, address indexed from, uint256 amount);

    error ZeroAddress();
    /// @notice `token` was never launched on the launchpad (it has no registered plugin).
    error UnknownToken(address token);
    /// @notice The launchpad called onLaunch for a token whose registered plugin is not this contract.
    error NotTokenPlugin(address token);
    /// @notice The onLaunch caller is neither the launchpad nor the token's registered plugin.
    error Unauthorized(address caller);
    error AlreadyConfigured(address token);
    error NotConfigured(address token);
    /// @notice This plugin takes no configuration, so its onLaunch data must be empty.
    error DataNotEmpty();
    /// @notice The onLaunch data is not the canonical ABI encoding of the plugin's configuration types.
    error NonCanonicalData();
    error LengthMismatch();
    /// @notice onFees was called with msg.value different from `amount`: every credit must be backed by the ETH
    ///         the same call carries.
    error WrongValue(uint256 amount, uint256 value);
    /// @notice ETH arrived outside onFees from someone other than the launchpad (only the launchpad's sell-out
    ///         buy refund may land in a plugin's receive()).
    error StrayEth(address from);
    /// @notice The address cannot receive fees: zero, this plugin, the launchpad, the migrator, the token itself,
    ///         or any launch token.
    error InvalidRecipient(address recipient);

    /// @notice The launchpad this plugin serves (fixed at deployment).
    function launchpad() external view returns (address);
    /// @notice True once `token` has been configured for this plugin; only configured tokens accept fees.
    function isConfigured(address token) external view returns (bool);
    /// @notice ETH this plugin currently holds for `token`: credited and not yet paid out, spent or distributed.
    ///         The plugin's ETH balance equals the sum of this over all tokens, plus any launchpad refund not yet
    ///         re-credited and anything forced in (neither is credited to any token and stays in the plugin).
    function ethHeld(address token) external view returns (uint256);
}
