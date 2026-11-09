// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Elysium is ArbOS: block.number is the parent-chain block, not the local execution block.
///         Use ArbSys for per-Elysium-block pacing; retain native block.number on historical non-Orbit targets.
library ElysiumClock {
    address internal constant ARBSYS = address(0x64);
    error ArbSysUnavailable();
    function blockNumber() internal view returns (uint256) {
        if (block.chainid != 99801 && block.chainid != 99901) return block.number;
        (bool ok, bytes memory result) = ARBSYS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        // Never silently fall back to the wrong clock on Elysium.
        if (!ok || result.length != 32) revert ArbSysUnavailable();
        return abi.decode(result, (uint256));
    }
}
