// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMintMarkFeePlugin} from "../../interfaces/IMintMarkFeePlugin.sol";
import {ILaunchFeePlugin} from "../../interfaces/plugins/ILaunchFeePlugin.sol";
import {ISplitPlugin} from "../../interfaces/plugins/ISplitPlugin.sol";
import {LaunchFeePluginBase} from "./LaunchFeePluginBase.sol";

/// @title SplitPlugin
/// @notice Shares each launch token's creator fees among up to 20 payees by fixed shares, set once at launch.
///         One deployment serves every token; each token's split is independent.
/// @dev The accounting of OpenZeppelin's PaymentSplitter, kept per token and driven by credited amounts instead of
///      the contract balance: a payee is owed `totalReceived(token) * share / totalShares(token)` in total and can
///      be paid that minus what they have been paid. mulDiv keeps this exact for any share size, so no configuration
///      can make release overflow. The sum of what all payees are owed never exceeds totalReceived, so the plugin
///      always covers every claim.
contract SplitPlugin is ISplitPlugin, LaunchFeePluginBase {
    /// @inheritdoc ISplitPlugin
    uint256 public constant MAX_PAYEES = 20;

    struct Split {
        uint256 totalShares;
        uint256 totalReceived;
        uint256 totalReleased;
        address[] payees;
    }

    mapping(address token => Split) private _splits;
    mapping(address token => mapping(address payee => uint256)) private _shares;
    mapping(address token => mapping(address payee => uint256)) private _released;

    constructor(address launchpad_) LaunchFeePluginBase(launchpad_) {}

    // ─── Hooks ────────────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkFeePlugin
    /// @dev `data` = abi.encode(address[] payees, uint256[] shares), canonically encoded.
    function onLaunch(address token, address creator, bytes calldata data) external nonReentrant {
        _configure(token, creator);

        (address[] memory payees, uint256[] memory shares) = abi.decode(data, (address[], uint256[]));
        if (keccak256(abi.encode(payees, shares)) != keccak256(data)) revert NonCanonicalData();
        uint256 count = payees.length;
        if (count == 0 || count > MAX_PAYEES) revert InvalidPayeeCount(count);
        if (shares.length != count) revert LengthMismatch();

        Split storage split = _splits[token];
        mapping(address payee => uint256) storage tokenShares = _shares[token];
        uint256 total = 0;
        for (uint256 i; i < count; ++i) {
            address payee = payees[i];
            uint256 share = shares[i];
            _checkRecipient(token, payee);
            if (share == 0) revert ZeroShare(payee);
            if (tokenShares[payee] != 0) revert DuplicatePayee(payee);
            tokenShares[payee] = share;
            split.payees.push(payee);
            total += share; // checked: shares whose sum overflows are rejected
        }
        split.totalShares = total;
        emit SplitConfigured(token, payees, shares);
    }

    /// @inheritdoc IMintMarkFeePlugin
    /// @dev Credits `token` with exactly the ETH this call carries. Zero is a no-op.
    function onFees(address token, uint256 amount) external payable nonReentrant {
        _requireConfigured(token);
        _requireExactValue(amount);
        if (amount == 0) return;
        _splits[token].totalReceived += amount;
        emit FeesReceived(token, msg.sender, amount);
    }

    // ─── Release ──────────────────────────────────────────────────────────────

    /// @inheritdoc ISplitPlugin
    /// @dev State is written before the send; a payee reentering from receive() finds nothing releasable.
    function release(address token, address payee) external nonReentrant returns (uint256 amount) {
        amount = releasable(token, payee);
        if (amount == 0) revert NothingToRelease(token, payee);
        _released[token][payee] += amount;
        _splits[token].totalReleased += amount;
        emit Released(token, payee, amount);
        Address.sendValue(payable(payee), amount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc ISplitPlugin
    function releasable(address token, address payee) public view returns (uint256) {
        uint256 share = _shares[token][payee];
        if (share == 0) return 0;
        Split storage split = _splits[token];
        uint256 owed = Math.mulDiv(split.totalReceived, share, split.totalShares);
        uint256 alreadyPaid = _released[token][payee];
        return owed > alreadyPaid ? owed - alreadyPaid : 0;
    }

    /// @inheritdoc ISplitPlugin
    function payeesOf(address token) external view returns (address[] memory payees, uint256[] memory shares) {
        payees = _splits[token].payees;
        uint256 count = payees.length;
        shares = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            shares[i] = _shares[token][payees[i]];
        }
    }

    /// @inheritdoc ISplitPlugin
    function sharesOf(address token, address payee) external view returns (uint256) {
        return _shares[token][payee];
    }

    /// @inheritdoc ISplitPlugin
    function totalShares(address token) external view returns (uint256) {
        return _splits[token].totalShares;
    }

    /// @inheritdoc ISplitPlugin
    function totalReceived(address token) external view returns (uint256) {
        return _splits[token].totalReceived;
    }

    /// @inheritdoc ISplitPlugin
    function totalReleased(address token) external view returns (uint256) {
        return _splits[token].totalReleased;
    }

    /// @inheritdoc ISplitPlugin
    function released(address token, address payee) external view returns (uint256) {
        return _released[token][payee];
    }

    /// @inheritdoc ILaunchFeePlugin
    function ethHeld(address token) external view returns (uint256) {
        Split storage split = _splits[token];
        return split.totalReceived - split.totalReleased;
    }
}
