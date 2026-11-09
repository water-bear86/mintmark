// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Seeds a graduated token's DEX pool with the curve's liquidity and locks it forever.
interface IMigrator {
    /// @notice The DEX router graduation targets (used by plugins that trade post-graduation).
    function router() external view returns (address);
    /// @notice The DEX's pair factory.
    function dexFactory() external view returns (address);
    /// @notice The wrapped native token the pools pair with.
    function weth() external view returns (address);

    /// @notice The pool `token` graduates into (its WETH pair), known before the pool exists.
    function poolFor(address token) external view returns (address);

    /// @notice Pulls `tokenAmount` from the caller, wraps msg.value to WETH, seeds the pool and burns the LP.
    function migrate(address token, uint256 tokenAmount) external payable returns (address pool, uint256 liquidity);
}
