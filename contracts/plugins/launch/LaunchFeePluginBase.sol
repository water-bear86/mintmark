// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMintMarkFeePlugin} from "../../interfaces/IMintMarkFeePlugin.sol";
import {IMintMarkLaunchpadLite} from "../../interfaces/IMintMarkLaunchpadLite.sol";
import {IMigrator} from "../../interfaces/IMigrator.sol";
import {ILaunchFeePlugin} from "../../interfaces/plugins/ILaunchFeePlugin.sol";

/// @title LaunchFeePluginBase
/// @notice What every MintMark reference creator-fee plugin must get identically right (the V13-SPEC §2.1 rules,
///         re-legged for ETH):
///         - who may configure a token: the launchpad, for a token whose plugin is this contract, or the token's
///           registered plugin (a Combo configuring its entries);
///         - configuration is write-once per token;
///         - fees are accepted only for configured tokens, from any caller, and must arrive as the call's own
///           msg.value, so every credit is backed by ETH received;
///         - ERC-165 support for IMintMarkFeePlugin.
/// @dev No owner, no admin, no pause, no upgrade and no sweep: nobody can redirect a token's fees.
///      ETH is accounted per token in each plugin's own storage, never inferred from this contract's balance.
abstract contract LaunchFeePluginBase is ILaunchFeePlugin, ReentrancyGuard {
    IMintMarkLaunchpadLite internal immutable LAUNCHPAD;

    mapping(address token => bool) private _configured;

    constructor(address launchpad_) {
        if (launchpad_ == address(0)) revert ZeroAddress();
        LAUNCHPAD = IMintMarkLaunchpadLite(launchpad_);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc ILaunchFeePlugin
    function launchpad() external view returns (address) {
        return address(LAUNCHPAD);
    }

    /// @inheritdoc ILaunchFeePlugin
    function isConfigured(address token) public view returns (bool) {
        return _configured[token];
    }

    /// @inheritdoc IERC165
    /// @dev True for IMintMarkFeePlugin and IERC165 only, so false for 0xffffffff as ERC-165 requires.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IMintMarkFeePlugin).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Authenticates an onLaunch call and marks `token` configured, once.
    ///      Launch-token addresses are predictable, so without this check anyone could configure a plugin for a
    ///      token that is about to be created. Two callers are accepted:
    ///        - the launchpad, for a token whose registered plugin is this contract (createToken registers the
    ///          curve, plugin included, before it calls onLaunch);
    ///        - the token's registered plugin itself: a Combo configuring the plugins it splits fees across.
    ///      A token that was never launched has no registered plugin (pluginOf returns zero) and is rejected.
    function _configure(address token, address creator) internal {
        if (_configured[token]) revert AlreadyConfigured(token);
        address registered = LAUNCHPAD.pluginOf(token);
        if (registered == address(0)) revert UnknownToken(token);
        if (msg.sender == address(LAUNCHPAD)) {
            if (registered != address(this)) revert NotTokenPlugin(token);
        } else if (msg.sender != registered) {
            revert Unauthorized(msg.sender);
        }
        _configured[token] = true;
        emit Configured(token, creator);
    }

    /// @dev onFees accepts any caller, because the carried value backs every credit, but only for a configured token.
    function _requireConfigured(address token) internal view {
        if (!_configured[token]) revert NotConfigured(token);
    }

    /// @dev Every credit must be backed by the ETH this very call carries (the ETH analogue of v1.3's exact pull).
    function _requireExactValue(uint256 amount) internal view {
        if (msg.value != amount) revert WrongValue(amount, msg.value);
    }

    /// @dev Rejects fee recipients where ETH would be stranded or would break this plugin's per-token accounting:
    ///      the zero address, this plugin, the launchpad, the migrator, WETH (its receive() mints WETH to the sender,
    ///      stranding it — review #1 L3), the DEX router and factory, the token, and any launch token (the curve
    ///      registry knows them all). A V2 pool rejects plain ETH by itself. Reads only the launchpad and the
    ///      migrator, never the recipient.
    function _checkRecipient(address token, address recipient) internal view {
        IMigrator migrator = IMigrator(LAUNCHPAD.migrator());
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(LAUNCHPAD)
                || recipient == address(migrator) || recipient == migrator.weth() || recipient == migrator.router()
                || recipient == migrator.dexFactory() || recipient == token
                || LAUNCHPAD.pluginOf(recipient) != address(0)
        ) revert InvalidRecipient(recipient);
    }
}
