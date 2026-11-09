// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./launchpad/MintMarkBase.sol";
import {ILaunchFeePlugin} from "../interfaces/plugins/ILaunchFeePlugin.sol";
import {SplitPlugin} from "../plugins/launch/SplitPlugin.sol";
import {PluginRegistry} from "../PluginRegistry.sol";

/// @notice Regressions for review round #1 (docs/reviews/CLAUDE-REVIEW-1.md, GROK-REVIEW-1.md). Each test asserts
///         the FIXED behaviour of a confirmed finding; the reviewers' PoCs asserted the vulnerable behaviour and
///         were replaced by this file in the fix commit.
contract Review1Regressions is MintMarkBase {
    // ─── H1: buy(to = pool) must not unlock the pre-graduation pool ───────────

    function test_h1_buyToThePoolReverts() public {
        address token = _create(300, creatorWallet);
        address pool = pad.poolOf(token);
        vm.prank(mallory);
        vm.expectRevert(IMintMarkLaunchpad.InvalidTo.selector);
        pad.buy{value: 1 ether}(token, 0, pool, type(uint256).max);
        // and the launchpad itself is no recipient either (inventory accounting)
        vm.prank(mallory);
        vm.expectRevert(IMintMarkLaunchpad.InvalidTo.selector);
        pad.buy{value: 1 ether}(token, 0, address(pad), type(uint256).max);
        assertFalse(ILaunchToken(token).poolUnlocked());
    }

    /// @dev Second line of defence: even a plain launchpad transfer into the pool must not unlock it — only the
    ///      migrator's pull (msg.sender != launchpad) or the vault's may. Pranking the launchpad simulates any
    ///      future launchpad code path that transfers with `from == launchpad`.
    function test_h1_plainLaunchpadTransferDoesNotUnlock() public {
        address token = _create(300, creatorWallet);
        address pool = pad.poolOf(token);
        vm.prank(address(pad));
        vm.expectRevert(ILaunchToken.PoolLocked.selector);
        IERC20(token).transfer(pool, 1);
        assertFalse(ILaunchToken(token).poolUnlocked());
    }

    /// @dev Grok's H1 escalation, inverted: pre-creating the pair and donating WETH wins the attacker nothing —
    ///      graduation still seeds it and every LP but the mock's minimum ends up at the dead address.
    function test_h1_preCreatedDonatedPairCannotCaptureTheGraduation() public {
        address token = _create(300, creatorWallet);
        address pool = pad.poolOf(token);

        // Attacker creates the pair early and donates a WETH side at an absurd price
        dexFactory.createPair(token, address(weth));
        vm.deal(mallory, 2 ether);
        vm.startPrank(mallory);
        weth.deposit{value: 1 ether}();
        weth.transfer(pool, 1 ether);
        MockPair(pool).sync();
        // No token side can arrive: the pool is locked and buys refuse to deliver there
        vm.expectRevert(IMintMarkLaunchpad.InvalidTo.selector);
        pad.buy{value: 1 ether}(token, 0, pool, type(uint256).max);
        vm.expectRevert(); // zero token side: the first-mint sqrt underflows the minimum liquidity
        MockPair(pool).mint(mallory);
        vm.stopPrank();

        _graduate(token);
        MockPair pair = MockPair(pool);
        assertEq(pair.balanceOf(mallory), 0, "the squatter holds no LP");
        assertEq(pair.balanceOf(DEAD) + 1000, pair.totalSupply(), "everything but the mock minimum is burned");
        _assertSolvent();
    }

    // ─── M2: a prefunded graduation vault must not poison the dividend stream ──

    function _predictVault(address token) internal view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(GraduationVault).creationCode, abi.encode(token, address(migrator))));
        return vm.computeCreate2Address(bytes32(uint256(uint160(token))), initCodeHash, address(pad));
    }

    function test_m2_prefundedVaultNeitherDilutesNorReverts() public {
        address token = _create(0, creatorWallet);
        address vaultAddr = _predictVault(token);

        // Attacker parks tokens at the predicted vault address long before any failure
        vm.prank(mallory);
        (uint256 bought,) = pad.buy{value: 1 ether}(token, 0, mallory, type(uint256).max);
        vm.prank(mallory);
        IERC20(token).transfer(vaultAddr, bought);

        // Migration fails: the vault is created and joins the excluded set WITH a balance
        dexFactory.setMintBroken(true);
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, type(uint256).max);
        assertEq(ILaunchToken(token).vault(), vaultAddr, "the predicted address is the vault");

        // Eligible supply excludes the vault's pre-parked balance
        ILaunchToken t = ILaunchToken(token);
        assertEq(t.eligibleSupply(), IERC20(token).balanceOf(bob), "only the real holder is eligible");

        // A full stream pays the real holder everything; the vault neither earns nor reverts
        vm.deal(carol, 2 ether);
        vm.prank(carol);
        t.distribute{value: 1 ether}();
        vm.warp(vm.getBlockTimestamp() + t.DRIP_PERIOD());
        assertEq(t.claimable(vaultAddr), 0, "excluded, no revert");
        assertEq(t.claimFor(vaultAddr), 0);
        uint256 bobShare = t.claimable(bob);
        assertLe(bobShare, 1 ether);
        assertApproxEqAbs(bobShare, 1 ether, 2, "the whole distribution reaches the real holder");
    }

    function test_m2_claimedBeforeExclusionDoesNotUnderflow() public {
        address token = _create(0, creatorWallet);
        address vaultAddr = _predictVault(token);
        vm.prank(mallory);
        pad.buy{value: 1 ether}(token, 0, vaultAddr, type(uint256).max); // deliver straight to the future vault

        // It earns and claims while still an ordinary address
        vm.deal(carol, 2 ether);
        vm.prank(carol);
        ILaunchToken(token).distribute{value: 1 ether}();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(ILaunchToken(token).claimFor(vaultAddr), 0);

        // Then the migration fails and the address becomes the vault — views must not revert
        dexFactory.setMintBroken(true);
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, type(uint256).max);
        assertEq(ILaunchToken(token).vault(), vaultAddr);
        assertEq(ILaunchToken(token).claimable(vaultAddr), 0, "clamped, not underflowed");
        assertEq(ILaunchToken(token).claimFor(vaultAddr), 0);

        // And the vault retry still seeds the pool once the DEX works — everything the vault holds, the
        // attacker's parked tokens included, becomes locked liquidity.
        uint256 vaultTokens = IERC20(token).balanceOf(vaultAddr);
        dexFactory.setMintBroken(false);
        GraduationVault(payable(vaultAddr)).migrate();
        assertEq(IERC20(token).balanceOf(pad.poolOf(token)), vaultTokens);
        assertEq(IERC20(token).balanceOf(vaultAddr), 0);
        assertGt(MockPair(pad.poolOf(token)).balanceOf(DEAD), 0);
    }

    // ─── L3: WETH, the router and the DEX factory are no fee destinations ─────

    function test_l3_wethRouterAndFactoryAreInvalidPlugins() public {
        address[3] memory bad = [address(weth), address(dexRouter), address(dexFactory)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(IMintMarkLaunchpad.InvalidPlugin.selector);
            pad.createToken("Bad", "BAD", "", 100, bad[i], "", 0, type(uint256).max);
        }
    }

    function test_l3_splitRefusesWethPayee() public {
        SplitPlugin split = new SplitPlugin(address(pad));
        address[] memory payees = new address[](2);
        (payees[0], payees[1]) = (alice, address(weth));
        uint256[] memory shares = new uint256[](2);
        (shares[0], shares[1]) = (1, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILaunchFeePlugin.InvalidRecipient.selector, address(weth)));
        pad.createToken("S", "S", "", 100, address(split), abi.encode(payees, shares), 0, type(uint256).max);
    }

    // ─── M1: registry squatting is recoverable; disclosure bounded ─────────────

    function test_m1_curatorDelistFreesASquattedAddress() public {
        PluginRegistry reg = new PluginRegistry(address(this), 0);
        address realAuthor = makeAddr("realAuthor");
        vm.prank(mallory);
        reg.list(address(0xdecaf), "Fake", "ipfs://fake", 9999);
        vm.prank(realAuthor);
        vm.expectRevert(abi.encodeWithSelector(PluginRegistry.AlreadyListed.selector, address(0xdecaf)));
        reg.list(address(0xdecaf), "Real", "", 0);

        reg.delist(address(0xdecaf));
        assertFalse(reg.isListed(address(0xdecaf)));
        vm.prank(realAuthor);
        reg.list(address(0xdecaf), "Real", "", 0);
        assertEq(reg.listingOf(address(0xdecaf)).author, realAuthor);
        assertEq(reg.pluginsLength(), 1);
    }

    function test_m1_authorFeeBpsCappedAndRenounceNeedsCollectedFees() public {
        PluginRegistry reg = new PluginRegistry(address(this), 0.001 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PluginRegistry.InvalidAuthorFeeBps.selector, uint16(10_001)));
        reg.list{value: 0.001 ether}(address(0xAB), "A", "", 10_001);
        vm.prank(alice);
        reg.list{value: 0.001 ether}(address(0xAB), "A", "", 10_000);

        vm.expectRevert(PluginRegistry.FeesPending.selector);
        reg.setCurator(address(0));
        reg.collectFees();
        reg.setCurator(address(0));
        assertEq(reg.curator(), address(0));
    }

    receive() external payable {} // this test contract is the registry curator above
}
