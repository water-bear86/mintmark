// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title The part of the MintMark launchpad that plugins rely on.
/// @notice `IMintMarkLaunchpad` extends this. Per-token views return zero values for an address that
///         was never launched (they do not revert), so plugins can use them in authorization checks.
interface IMintMarkLaunchpadLite {
    /// @notice The migrator graduation seeds the DEX pool through, fixed at deployment.
    function migrator() external view returns (address);
    /// @notice Platform fee in basis points (50 = 0.5%), charged on every curve trade.
    function FEE_BPS() external view returns (uint256);

    function pluginOf(address token) external view returns (address);
    function creatorOf(address token) external view returns (address);
    function creatorFeeBpsOf(address token) external view returns (uint16);
    /// @notice The DEX pool the token graduates into (predicted at launch; exists once seeded).
    function poolOf(address token) external view returns (address);
    function isGraduated(address token) external view returns (bool);
    /// @notice The curve's virtual ETH reserve (wei); 0 for an unknown token.
    function virtualEthOf(address token) external view returns (uint256);

    /// @notice Curve buy (see IMintMarkLaunchpad). Spends msg.value; refunds the unspent part only on the buy
    ///         that sells out the curve. Reverts Expired if block.timestamp > deadline.
    function buy(address token, uint256 minTokensOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut, uint256 ethSpent);
}
