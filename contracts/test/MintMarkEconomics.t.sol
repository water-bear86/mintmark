// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./launchpad/MintMarkBase.sol";

/// @notice The 30 HYPE net baseline excludes fees and preserves the existing curve/token allocation.
contract MintMarkEconomicsTest is MintMarkBase {
    function test_calibrationPreservesAllocationAndFreshNetTarget() public {
        assertEq(pad.TOTAL_SUPPLY(), 1_000_000_000e18);
        assertEq(pad.CURVE_SUPPLY(), 800_000_000e18);
        assertEq(pad.POOL_SUPPLY(), 200_000_000e18);
        assertEq(pad.VIRTUAL_TOKENS_0(), 1_066_666_667e18);
        uint256 residual = pad.VIRTUAL_TOKENS_0() - pad.CURVE_SUPPLY();
        assertEq(pad.VIRTUAL_ETH_0(), 30 ether * residual / pad.CURVE_SUPPLY());
        assertEq(_divCeil(pad.VIRTUAL_ETH_0() * pad.VIRTUAL_TOKENS_0(), residual) - pad.VIRTUAL_ETH_0(), 30 ether);
        // Multiplying the previous rounded scale by six misses the exact target.
        uint256 naive = 6 * 1_666_666_666_666_666_667;
        assertLt(_divCeil(naive * pad.VIRTUAL_TOKENS_0(), residual) - naive, 30 ether);
    }

    function test_zeroFeeGraduationBoundaryAndRefund() public {
        address token = _create();
        uint256 gross = 30 ether + _divCeil(30 ether * 50, 9950);
        (uint256 below,,,, bool graduatesBelow) = pad.quoteBuy(token, gross - 1);
        assertFalse(graduatesBelow);
        assertLt(below, CURVE_SUPPLY);
        (uint256 amount, uint256 platform, uint256 creator, uint256 spent, bool graduates) = pad.quoteBuy(token, gross);
        assertTrue(graduates);
        assertEq(amount, CURVE_SUPPLY);
        assertEq(spent, gross);
        assertEq(platform, gross - 30 ether);
        assertEq(creator, 0);
        uint256 beforeBalance = bob.balance;
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, amount, bob, type(uint256).max);
        assertEq(beforeBalance - bob.balance, gross, "overpayment refunded");
        assertEq(weth.balanceOf(pad.poolOf(token)), 30 ether);
        assertEq(IERC20(token).balanceOf(pad.poolOf(token)), POOL_SUPPLY);
        _assertSolvent();
    }

    function testFuzz_creatorFeesDoNotReduceFreshNetLiquidity(uint16 rawBps) public {
        uint16 bps = uint16(bound(rawBps, 0, 1000));
        address token = _create(bps, creatorWallet);
        uint256 gross = 30 ether + _divCeil(30 ether * (50 + uint256(bps)), 9950 - uint256(bps));
        vm.prank(bob);
        (, uint256 spent) = pad.buy{value: 40 ether}(token, CURVE_SUPPLY, bob, type(uint256).max);
        assertEq(spent, gross);
        assertEq(weth.balanceOf(pad.poolOf(token)), 30 ether);
        assertEq(pad.pendingFees() + pad.pendingCreatorFees(token), gross - 30 ether);
        _assertSolvent();
    }

    function test_multiTradeRoundingIsNotAnExact30HardCap() public {
        address token = _create();
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(token, 0, alice, type(uint256).max);
        _graduate(token);
        // Each trade rounds the token reserve upward and recomputes k. Even this two-buy path
        // seeds one extra wei, so the exact 30 HYPE statement applies only to the fresh baseline.
        assertEq(weth.balanceOf(pad.poolOf(token)), 30 ether + 1);
        _assertSolvent();
    }
}
