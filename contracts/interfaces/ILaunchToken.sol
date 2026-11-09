// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ILaunchTokenExtensions.sol";

/// @notice A token launched on the MintMark launchpad: fixed 1B supply minted once to the launchpad, no owner,
///         no mint. Holders can burn; ETH dividends are built in. Its DEX pool (predicted at launch) is closed
///         to deposits until graduation seeds it, so the launchpad sets the pool's opening price.
interface ILaunchToken is IERC20, ILaunchTokenExtensions {
    error OnlyLaunchpad();
    /// @notice A pull to anywhere but the launchpad (a curve sell moves the seller's tokens back to the curve).
    error InvalidPullTarget();
    error PoolAlreadySet();
    error VaultAlreadySet();
    /// @notice A deposit into the DEX pool before graduation unlocked it (only the launchpad or the vault may).
    error PoolLocked();

    function launchpad() external view returns (address);
    /// @notice The DEX pool the token graduates into: closed to deposits until graduation, excluded from dividends.
    function pool() external view returns (address);
    /// @notice GraduationVault holding the liquidity if seeding the pool failed; zero otherwise.
    function vault() external view returns (address);
    /// @notice Set the moment the pool is first seeded. Until then only the launchpad or the vault can send to it.
    function poolUnlocked() external view returns (bool);

    /// @notice The smallest eligible supply dividends run on (one whole token). Below it `eligibleSupply()` reports 0
    ///         and the dividend stream pauses, which bounds the dividend-per-share growth a near-empty supply would
    ///         otherwise allow.
    function MIN_ELIGIBLE_SUPPLY() external view returns (uint256);
    /// @notice ETH dividends `holder` has claimed so far.
    function claimed(address holder) external view returns (uint256);

    /// @notice Launchpad only, once: the predicted DEX pool that stays closed to deposits until graduation.
    function initPool(address pool) external;
    /// @notice Launchpad only, once: the graduation vault (created only when seeding the pool failed).
    function setVault(address vault) external;
    /// @notice Moves a seller's tokens back to the launchpad without an ERC-20 approval. Launchpad only, and only
    ///         to itself; it passes its own `msg.sender` as `from`.
    function pull(address from, address to, uint256 amount) external;
}
