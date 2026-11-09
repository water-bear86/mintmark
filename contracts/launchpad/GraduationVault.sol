// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMigrator.sol";

/// @title GraduationVault (MintMark)
/// @notice Holds a graduated token's liquidity if seeding its DEX pool failed. Created by the launchpad, one per
///         token. It has no owner and no withdraw: the only way out is `migrate()`, which anyone can call to retry
///         the pool. A native-ETH-only port of Metapad's GraduationVault.
contract GraduationVault {
    using SafeERC20 for IERC20;

    address public immutable token;
    address public immutable migrator;

    event Migrated(address indexed pool, uint256 tokenAmount, uint256 ethAmount);

    constructor(address token_, address migrator_) {
        token = token_;
        migrator = migrator_;
    }

    receive() external payable {}

    /// @notice Retry seeding the pool with everything the vault holds.
    function migrate() external returns (address pool) {
        uint256 tokenAmount = IERC20(token).balanceOf(address(this));
        IERC20(token).forceApprove(migrator, tokenAmount);
        uint256 ethAmount = address(this).balance;
        (pool,) = IMigrator(migrator).migrate{value: ethAmount}(token, tokenAmount);
        emit Migrated(pool, tokenAmount, ethAmount);
    }
}
