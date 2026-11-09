// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IUniswapV2Router, IUniswapV2Factory, IUniswapV2Pair} from "../launchpad/V2Migrator.sol";

/// @notice Read-only checks performed before any deployment transaction is broadcast.
library ElysiumPreflight {
    uint256 internal constant TESTNET = 99801;
    uint256 internal constant MAINNET = 99901;
    address internal constant TESTNET_WHYPE = 0xCD57F65c2B0e5881CFC2E609F7CD53b746E1F234;
    error WrongChain();
    error InvalidConfiguration();
    error InvalidDex();

    function validate(uint256 expectedChain, address router, address wrappedHype, bytes32 pairHash) internal view {
        if ((expectedChain != TESTNET && expectedChain != MAINNET) || block.chainid != expectedChain) revert WrongChain();
        if (router.code.length == 0 || wrappedHype.code.length == 0 || pairHash == bytes32(0)) revert InvalidConfiguration();
        if (expectedChain == TESTNET && wrappedHype != TESTNET_WHYPE) revert InvalidConfiguration();
        IUniswapV2Router r = IUniswapV2Router(router);
        if (r.WETH() != wrappedHype) revert InvalidDex();
        address factory = r.factory();
        if (factory.code.length == 0 || IUniswapV2Factory(factory).allPairsLength() == 0) revert InvalidDex();
        address probe = IUniswapV2Factory(factory).allPairs(0);
        if (probe.code.length == 0) revert InvalidDex();
        address t0 = IUniswapV2Pair(probe).token0();
        address t1 = IUniswapV2Pair(probe).token1();
        if (t0 == address(0) || t0 >= t1) revert InvalidDex();
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(t0, t1)), pairHash)))));
        if (predicted != probe || IUniswapV2Factory(factory).getPair(t0, t1) != probe) revert InvalidDex();
    }
}
