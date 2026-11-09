// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./launchpad/MintMarkBase.sol";

contract RejectingWallet {
    bool public accept;

    function setAccept(bool v) external {
        accept = v;
    }

    receive() external payable {
        require(accept, "rejects ETH");
    }
}

/// @notice Creator fees, plugins, and graduation through the migrator into the DEX pool.
contract MintMarkLaunchpadTest is MintMarkBase {
    event CreatorFeesCollected(address indexed token, address indexed plugin, uint256 amount);
    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed plugin,
        address pair,
        uint16 creatorFeeBps,
        string name,
        string symbol,
        string metadataURI
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // 1 — Creator-fee math on the curve
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_buyFees_matchTheSpecAndNeverFavourTheTrader(uint64 rawEthIn, uint16 rawBps, uint64 rawPre) public {
        uint16 bps = uint16(bound(rawBps, 0, 1000));
        address token = _create(bps, creatorWallet);
        // Move the curve to a random point first
        uint256 pre = bound(rawPre, 0, (20_000e6 * 2e8));
        if (pre > 300) {
            vm.prank(carol);
            pad.buy{value: pre}(token, 0, carol, type(uint256).max);
        }
        IMintMarkLaunchpad.Curve memory c = pad.curves(token);
        uint256 ethIn = bound(rawEthIn, 1, (3_000e6 * 2e8));

        uint256 expPlatform = _divCeil(ethIn * FEE_BPS, BPS);
        uint256 expCreator = _divCeil(ethIn * bps, BPS);
        if (expPlatform + expCreator >= ethIn) {
            vm.expectRevert(IMintMarkLaunchpad.ZeroAmount.selector);
            pad.quoteBuy(token, ethIn);
            return;
        }
        uint256 k = uint256(c.virtualEth) * uint256(c.virtualTokens);
        uint256 net = ethIn - expPlatform - expCreator;
        uint256 expTokens = uint256(c.virtualTokens) - _divCeil(k, uint256(c.virtualEth) + net);
        if (expTokens == 0 || expTokens >= CURVE_SUPPLY - c.tokensSold) return; // dust or sell-out: covered elsewhere

        uint256 feesBefore = pad.pendingFees();
        uint256 creatorBefore = pad.pendingCreatorFees(token);
        vm.prank(alice);
        (uint256 tokensOut, uint256 spent) = pad.buy{value: ethIn}(token, 0, alice, type(uint256).max);

        uint256 platformFee = pad.pendingFees() - feesBefore;
        uint256 creatorFee = pad.pendingCreatorFees(token) - creatorBefore;
        assertEq(spent, ethIn);
        assertEq(tokensOut, expTokens);
        assertEq(platformFee, expPlatform, "platform = ceil(ethIn*50/1e4)");
        assertEq(creatorFee, expCreator, "creator = ceil(ethIn*c/1e4)");
        assertEq(uint256(pad.curves(token).virtualEth), uint256(c.virtualEth) + net, "net reaches the curve");
        // Rounding never favours the trader: each fee is at least its exact share
        assertGe(platformFee * BPS, ethIn * FEE_BPS);
        assertGe(creatorFee * BPS, ethIn * bps);
        if (bps == 0) assertEq(creatorFee, 0);
        _assertSolvent();
    }

    function testFuzz_sellFees_matchTheSpecAndNeverFavourTheTrader(uint64 rawBuy, uint96 rawSell, uint16 rawBps) public {
        uint16 bps = uint16(bound(rawBps, 0, 1000));
        address token = _create(bps, creatorWallet);
        vm.prank(alice);
        (uint256 bought,) = pad.buy{value: bound(rawBuy, (1e6 * 2e8), (20_000e6 * 2e8))}(token, 0, alice, type(uint256).max);
        uint256 tokensIn = bound(rawSell, 1, bought);

        IMintMarkLaunchpad.Curve memory c = pad.curves(token);
        uint256 k = uint256(c.virtualEth) * uint256(c.virtualTokens);
        uint256 gross = uint256(c.virtualEth) - _divCeil(k, uint256(c.virtualTokens) + tokensIn);
        uint256 expPlatform = _divCeil(gross * FEE_BPS, BPS);
        uint256 expCreator = _divCeil(gross * bps, BPS);
        if (expPlatform + expCreator >= gross) {
            vm.prank(alice);
            vm.expectRevert(IMintMarkLaunchpad.ZeroAmount.selector);
            pad.sell(token, tokensIn, 0, alice, type(uint256).max);
            return;
        }

        uint256 feesBefore = pad.pendingFees();
        uint256 creatorBefore = pad.pendingCreatorFees(token);
        uint256 usdcBefore = alice.balance;
        vm.prank(alice);
        uint256 out = pad.sell(token, tokensIn, 0, alice, type(uint256).max);

        uint256 platformFee = pad.pendingFees() - feesBefore;
        uint256 creatorFee = pad.pendingCreatorFees(token) - creatorBefore;
        assertEq(platformFee, expPlatform);
        assertEq(creatorFee, expCreator);
        assertEq(out, gross - platformFee - creatorFee, "fees sum exactly");
        assertEq(alice.balance - usdcBefore, out);
        assertEq(uint256(pad.curves(token).virtualEth), uint256(c.virtualEth) - gross);
        assertGe(platformFee * BPS, gross * FEE_BPS);
        assertGe(creatorFee * BPS, gross * bps);
        _assertSolvent();
    }

    /// @dev The sell-out buy: exact-fill gross, the cap, and the fee split (V13-SPEC §5).
    function testFuzz_exactFillFees(uint64 rawPre, uint64 rawOffer, uint16 rawBps) public {
        uint16 bps = uint16(bound(rawBps, 0, 1000));
        address token = _create(bps, creatorWallet);
        uint256 pre = bound(rawPre, 0, (24_000e6 * 2e8));
        if (pre > 300) {
            vm.prank(carol);
            pad.buy{value: pre}(token, 0, carol, type(uint256).max);
        }
        IMintMarkLaunchpad.Curve memory c = pad.curves(token);
        if (c.graduated) return;
        uint256 remaining = CURVE_SUPPLY - c.tokensSold;
        uint256 k = uint256(c.virtualEth) * uint256(c.virtualTokens);
        uint256 net = _divCeil(k, uint256(c.virtualTokens) - remaining) - uint256(c.virtualEth);
        uint256 feeBps = FEE_BPS + bps;
        uint256 uncapped = net + _divCeil(net * feeBps, BPS - feeBps);
        // Offers from a little below the uncapped gross (the cap may bite) to far above it
        uint256 offer = bound(rawOffer, uncapped - uncapped / 50, uncapped * 3);

        (uint256 qTokens, uint256 qPlatform, uint256 qCreator, uint256 qSpent, bool qGraduates) = pad.quoteBuy(token, offer);
        if (!qGraduates) return;

        uint256 feesBefore = pad.pendingFees();
        uint256 creatorBefore = pad.pendingCreatorFees(token);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        (uint256 tokensOut, uint256 spent) = pad.buy{value: offer}(token, 0, bob, type(uint256).max);

        // Whenever the offer sells out, the uncapped exact-fill gross fits in it: the cap never binds (see
        // testFuzz_sellOutNeedsExactlyTheExactFillGross); the contract keeps the min() as the spec's belt and braces.
        assertLe(uncapped, offer, "the exact-fill gross never exceeds a sell-out offer");
        uint256 expSpent = uncapped < offer ? uncapped : offer;
        uint256 totalFee = expSpent - net;
        uint256 expPlatform = _divCeil(totalFee * FEE_BPS, feeBps);
        uint256 platformFee = pad.pendingFees() - feesBefore;
        uint256 creatorFee = pad.pendingCreatorFees(token) - creatorBefore;
        assertEq(tokensOut, remaining, "fills exactly the remainder");
        assertEq(spent, expSpent, "min(offer, net + ceil(net*f/(1e4-f)))");
        assertLe(spent, offer, "never more than offered");
        assertEq(bobBefore - bob.balance, spent, "pulled exactly ethSpent");
        assertEq(platformFee, expPlatform, "platform = ceil(totalFee*50/(50+c))");
        assertEq(creatorFee, totalFee - expPlatform, "creator = the rest");
        assertEq(platformFee + creatorFee, spent - net, "fees sum exactly");
        assertEq(weth.balanceOf(pad.poolOf(token)), uint256(c.virtualEth) + net - VIRTUAL_ETH_0, "seed = float + net");
        // Not in the trader's favour: the total fee is at least the proportional fee on what was paid
        assertGe((spent - net) * BPS, spent * feeBps);
        // The quote is the same path
        assertEq(qTokens, tokensOut);
        assertEq(qSpent, spent);
        assertEq(qPlatform, expPlatform);
        assertEq(qCreator, totalFee - expPlatform);
        assertTrue(pad.isGraduated(token));
        _assertSolvent();
    }

    /// @dev The exact sell-out-from-fresh vectors at the ETH constants (net = ceil(k/(VT0-CURVE)) - V0, gross adds
    ///      the 0.5% the spec way), recomputed independently for this port.
    function test_zeroCreatorFee_exactSellOutVectors() public {
        address token = _create(0, creatorWallet);
        vm.prank(alice);
        (uint256 tokensOut, uint256 spent) = pad.buy{value: 1_000 ether}(token, 0, alice, type(uint256).max);
        assertEq(tokensOut, CURVE_SUPPLY);
        assertEq(spent, 30150753768844221106);
        assertEq(pad.pendingFees(), 150753768844221106);
        assertEq(pad.pendingCreatorFees(token), 0);
        assertEq(weth.balanceOf(pad.poolOf(token)), 30 ether);
    }

    function test_creatorFee_maxEdge() public {
        address token = _create(1000, creatorWallet);
        // 0.02 ETH buy: 0.0001 platform, 0.002 creator, 0.0179 net
        (uint256 qTokens, uint256 qPlatform, uint256 qCreator, uint256 qSpent,) = pad.quoteBuy(token, 0.02 ether);
        assertEq(qPlatform, 0.0001 ether);
        assertEq(qCreator, 0.002 ether);
        assertEq(qSpent, 0.02 ether);
        vm.prank(alice);
        (uint256 tokensOut,) = pad.buy{value: 0.02 ether}(token, 0, alice, type(uint256).max);
        assertEq(tokensOut, qTokens);
        assertEq(pad.curves(token).virtualEth, VIRTUAL_ETH_0 + 0.0179 ether);
        assertEq(pad.pendingCreatorFees(token), 0.002 ether);

        // The sell-out at 10.5% total: gross = net + ceil(net*1050/8950)
        IMintMarkLaunchpad.Curve memory c = pad.curves(token);
        uint256 remaining = CURVE_SUPPLY - c.tokensSold;
        uint256 k = uint256(c.virtualEth) * uint256(c.virtualTokens);
        uint256 net = _divCeil(k, uint256(c.virtualTokens) - remaining) - uint256(c.virtualEth);
        uint256 gross = net + _divCeil(net * 1050, 8950);
        vm.prank(bob);
        (, uint256 spent) = pad.buy{value: (1_000_000e6 * 2e8)}(token, 0, bob, type(uint256).max);
        assertEq(spent, gross);
        uint256 totalFee = gross - net;
        assertEq(pad.pendingCreatorFees(token), 0.002 ether + totalFee - _divCeil(totalFee * 50, 1050));
        _assertSolvent();
    }

    function test_creatorFee_aboveMaxReverts() public {
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.CreatorFeeTooHigh.selector);
        pad.createToken("Greedy", "GRDY", "", 1001, alice, "", 0, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.CreatorFeeTooHigh.selector);
        pad.createToken("Greedy", "GRDY", "", type(uint16).max, alice, "", 0, type(uint256).max);
        vm.prank(alice);
        pad.createToken("Fair", "FAIR", "", 1000, alice, "", 0, type(uint256).max); // the edge is allowed
    }

    function test_creatorFee_dustBuysAndSellsRevertCleanly() public {
        address token = _create(1000, creatorWallet);
        // ethIn 2: 1 platform + 1 creator = everything → ZeroAmount, not a panic
        vm.expectRevert(IMintMarkLaunchpad.ZeroAmount.selector);
        pad.quoteBuy(token, 2);
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.ZeroAmount.selector);
        pad.buy{value: 2}(token, 0, alice, type(uint256).max);
        vm.prank(alice);
        (uint256 tokensOut,) = pad.buy{value: (100e6 * 2e8)}(token, 0, alice, type(uint256).max);
        // A sell grossing 1 or 2 units: the two rounded-up fees (1 + 1) eat it all → ZeroAmount, not an underflow
        IMintMarkLaunchpad.Curve memory c = pad.curves(token);
        uint256 tokensIn = uint256(c.virtualTokens) * 3 / (2 * uint256(c.virtualEth));
        uint256 k = uint256(c.virtualEth) * uint256(c.virtualTokens);
        uint256 gross = uint256(c.virtualEth) - _divCeil(k, uint256(c.virtualTokens) + tokensIn);
        assertTrue(gross == 1 || gross == 2, "grosses a unit or two");
        vm.expectRevert(IMintMarkLaunchpad.ZeroAmount.selector);
        pad.quoteSell(token, tokensIn);
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.ZeroAmount.selector);
        pad.sell(token, tokensIn, 0, alice, type(uint256).max);
        assertGt(tokensOut, tokensIn);
    }

    function test_creatorsOwnFirstBuyPaysTheCreatorFee() public {
        vm.prank(alice);
        address token = pad.createToken{value: (1_000e6 * 2e8)}("Mine", "MINE", "", 700, alice, "", 0, type(uint256).max);
        assertEq(pad.pendingCreatorFees(token), _divCeil((1_000e6 * 2e8) * 700, BPS));
        assertEq(pad.pendingFees(), _divCeil((1_000e6 * 2e8) * 50, BPS));
    }

    function testFuzz_roundTripWithCreatorFeeNeverProfits(uint64 rawIn, uint16 rawBps) public {
        address token = _create(uint16(bound(rawBps, 0, 1000)), creatorWallet);
        uint256 ethIn = bound(rawIn, 1e4, (5_000e6 * 2e8));
        uint256 before = alice.balance;
        vm.prank(alice);
        (uint256 tokensOut,) = pad.buy{value: ethIn}(token, 0, alice, type(uint256).max);
        vm.prank(alice);
        try pad.sell(token, tokensOut, 0, alice, type(uint256).max) {} catch {}
        assertLe(alice.balance, before, "a buy followed by a sell never returns more than was paid");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2 — Accrual and collection (V13-SPEC §2.1)
    // ═══════════════════════════════════════════════════════════════════════════

    function _accrue(address token, uint256 ethIn) internal returns (uint256 owed) {
        vm.prank(carol);
        pad.buy{value: ethIn}(token, 0, carol, type(uint256).max);
        owed = pad.pendingCreatorFees(token);
        assertGt(owed, 0);
    }

    function test_collect_eoaPluginGetsAPlainTransfer() public {
        address token = _create(500, creatorWallet);
        uint256 owed = _accrue(token, (1_000e6 * 2e8));
        vm.expectEmit(true, true, false, true, address(pad));
        emit CreatorFeesCollected(token, creatorWallet, owed);
        vm.prank(mallory); // permissionless
        assertEq(pad.collectCreatorFees(token), owed);
        assertEq(creatorWallet.balance, owed);
        assertEq(pad.pendingCreatorFees(token), 0);
        assertEq(pad.collectCreatorFees(token), 0, "nothing left");
        _assertSolvent();
    }

    function test_collect_beforeGraduationProtectsOtherFeesAndStoredRecipient() public {
        address token = _create(500, creatorWallet);
        address other = _create(1000, bob);
        uint256 owed = _accrue(token, 1 ether);
        uint256 otherOwed = _accrue(other, 2 ether);
        uint256 platform = pad.pendingFees();
        uint256 reserve = pad.virtualEthOf(token);
        uint256 balanceBefore = address(pad).balance;
        uint256 callerBefore = mallory.balance;
        uint256 creatorBefore = alice.balance;
        assertFalse(pad.isGraduated(token), "no graduation needed to collect");
        assertEq(pad.pluginOf(token), creatorWallet);
        vm.prank(mallory);
        assertEq(pad.collectCreatorFees(token), owed);
        assertEq(creatorWallet.balance, owed, "only stored destination receives fees");
        assertEq(mallory.balance, callerBefore, "permissionless caller gets nothing");
        assertEq(alice.balance, creatorBefore, "creator cannot redirect the destination");
        assertEq(pad.pluginOf(token), creatorWallet);
        assertEq(pad.pendingFees(), platform, "platform accrual untouched");
        assertEq(pad.pendingCreatorFees(other), otherOwed, "other token accrual untouched");
        assertEq(pad.virtualEthOf(token), reserve, "curve reserve untouched");
        assertEq(address(pad).balance, balanceBefore - owed);
        vm.prank(alice);
        assertEq(pad.collectCreatorFees(token), 0, "repeat collection is empty");
        assertEq(creatorWallet.balance, owed);
        _assertSolvent();
    }

    function test_collect_reentrantPluginCannotStealFeesOrCurveReserves() public {
        ReentrantPlugin plugin = new ReentrantPlugin(pad);
        vm.deal(address(plugin), 2 ether);
        address token = _create(500, address(plugin));
        address other = _create(500, creatorWallet);
        uint256 owed = _accrue(token, 1 ether);
        uint256 otherOwed = _accrue(other, 1 ether);
        uint256 platform = pad.pendingFees();
        uint256 reserve = pad.virtualEthOf(token);
        uint256 beforeBalance = address(plugin).balance;
        uint256 attemptsBefore = plugin.errorsLength();
        vm.prank(mallory);
        assertEq(pad.collectCreatorFees(token), owed);
        assertFalse(plugin.anyReentrySucceeded());
        assertEq(plugin.errorsLength(), attemptsBefore + 5);
        for (uint256 i = attemptsBefore; i < plugin.errorsLength(); ++i) {
            assertEq(plugin.errors(i), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        }
        assertEq(address(plugin).balance, beforeBalance + owed, "only accrued fees leave");
        assertEq(pad.pendingCreatorFees(token), 0);
        assertEq(pad.pendingCreatorFees(other), otherOwed);
        assertEq(pad.pendingFees(), platform);
        assertEq(pad.virtualEthOf(token), reserve);
        assertEq(pad.collectCreatorFees(token), 0);
        _assertSolvent();
    }

    function test_collect_contractWithoutErc165GetsAPlainTransferAndNoHooks() public {
        HooklessRecorder wallet = new HooklessRecorder();
        vm.prank(alice);
        address token = pad.createToken{value: (50e6 * 2e8)}("Safe", "SAFE", "", 300, address(wallet), "", 0, type(uint256).max);
        uint256 owed = _accrue(token, (1_000e6 * 2e8));
        pad.collectCreatorFees(token);
        assertEq(address(wallet).balance, owed);
        assertEq(wallet.hookCalls(), 0, "neither onLaunch nor onFees is called");
        _assertSolvent();
    }

    function test_collect_lyingErc165IsTreatedAsAPlainAddress() public {
        LyingPlugin liar = new LyingPlugin();
        vm.prank(alice);
        address token = pad.createToken("Liar", "LIE", "", 300, address(liar), "", 0, type(uint256).max);
        uint256 owed = _accrue(token, (1_000e6 * 2e8));
        pad.collectCreatorFees(token);
        assertEq(address(liar).balance, owed);
        assertEq(liar.hookCalls(), 0);
    }

    function test_collect_gasBurningErc165ProbeIsTreatedAsAPlainAddress() public {
        GasGuzzlerPlugin guzzler = new GasGuzzlerPlugin();
        vm.prank(alice);
        address token = pad.createToken{value: (10e6 * 2e8)}("Guzzle", "GUZ", "", 300, address(guzzler), "", 0, type(uint256).max);
        uint256 owed = _accrue(token, (1_000e6 * 2e8));
        pad.collectCreatorFees(token);
        assertEq(address(guzzler).balance, owed);
        assertEq(guzzler.hookCalls(), 0);
        _assertSolvent();
    }

    function test_collect_exactPullPluginWorks() public {
        ExactPlugin plugin = new ExactPlugin(pad);
        address token = _create(250, address(plugin));
        uint256 owed = _accrue(token, (2_000e6 * 2e8));
        uint256 padBefore = address(pad).balance;
        assertEq(pad.collectCreatorFees(token), owed);
        assertEq(plugin.received(token), owed);
        assertEq(plugin.feeCalls(), 1);
        assertEq(address(plugin).balance, owed);
        assertEq(padBefore - address(pad).balance, owed);
        _assertSolvent();
    }

    function test_collect_forwardingPluginStillCreditsExactly() public {
        MisbehavingPlugin plugin = new MisbehavingPlugin();
        plugin.setMode(MisbehavingPlugin.Mode.Forward);
        address token = _create(250, address(plugin));
        uint256 owed = _accrue(token, (2_000e6 * 2e8));
        pad.collectCreatorFees(token);
        assertEq(plugin.THIRD_PARTY().balance, owed);
        _assertSolvent();
    }

    function _assertCollectionRevertsAndKeepsFees(MisbehavingPlugin.Mode mode, bytes memory expected) internal {
        MisbehavingPlugin plugin = new MisbehavingPlugin();
        address token = _create(400, address(plugin));
        uint256 owed = _accrue(token, (1_000e6 * 2e8));
        plugin.setMode(mode);
        uint256 padBefore = address(pad).balance;
        if (expected.length == 0) vm.expectRevert();
        else vm.expectRevert(expected);
        pad.collectCreatorFees(token);
        assertEq(pad.pendingCreatorFees(token), owed, "fees stay accrued");
        assertEq(address(pad).balance, padBefore, "nothing left the launchpad");
        _assertSolvent();

        // Trading is unaffected by the broken plugin
        vm.prank(alice);
        (uint256 got,) = pad.buy{value: (100e6 * 2e8)}(token, 0, alice, type(uint256).max);
        vm.prank(alice);
        pad.sell(token, got, 0, alice, type(uint256).max);
        assertGt(pad.pendingCreatorFees(token), owed);

        // Fixing the plugin's behaviour lets the same fees through, exactly
        plugin.setMode(MisbehavingPlugin.Mode.Exact);
        uint256 all = pad.pendingCreatorFees(token);
        assertEq(pad.collectCreatorFees(token), all);
        assertEq(address(plugin).balance, all);
        _assertSolvent();
    }

    function test_collect_revertingPluginKeepsFeesAccrued() public {
        _assertCollectionRevertsAndKeepsFees(MisbehavingPlugin.Mode.Revert, bytes("plugin broken"));
    }

    function test_collect_pluginSendingEthBackReverts() public {
        // The launchpad's receive() refuses, so a plugin trying to push value back fails the collection whole.
        _assertCollectionRevertsAndKeepsFees(MisbehavingPlugin.Mode.SendBack, "");
    }

    function test_collect_plainDestinationThatRejectsEthKeepsFeesAccrued() public {
        RejectingWallet wallet = new RejectingWallet();
        vm.prank(alice);
        address token = pad.createToken("Reject", "RJCT", "", 400, address(wallet), "", 0, type(uint256).max);
        uint256 owed = _accrue(token, 0.2 ether);
        uint256 balanceBefore = address(pad).balance;
        uint256 platform = pad.pendingFees();
        uint256 reserve = pad.virtualEthOf(token);
        vm.expectRevert();
        pad.collectCreatorFees(token);
        assertEq(pad.pendingCreatorFees(token), owed, "fees stay accrued");
        assertEq(address(pad).balance, balanceBefore);
        assertEq(address(wallet).balance, 0);
        assertEq(pad.pendingFees(), platform);
        assertEq(pad.virtualEthOf(token), reserve);
        _assertSolvent();
        wallet.setAccept(true);
        assertEq(pad.collectCreatorFees(token), owed);
        assertEq(address(wallet).balance, owed);
    }

    /// @dev V13-SPEC §6.3: a broken plugin never blocks a buy, a sell, a graduation or another token's collection.
    function test_brokenPluginNeverBlocksTradingGraduationOrOtherTokens() public {
        MisbehavingPlugin broken = new MisbehavingPlugin();
        broken.setMode(MisbehavingPlugin.Mode.Revert);
        ExactPlugin good = new ExactPlugin(pad);
        address bad = _create(1000, address(broken));
        address fine = _create(1000, address(good));

        // Trade both, collect the good one while the bad one is stuck
        vm.prank(alice);
        (uint256 got,) = pad.buy{value: (500e6 * 2e8)}(bad, 0, alice, type(uint256).max);
        vm.prank(alice);
        pad.sell(bad, got / 2, 0, alice, type(uint256).max);
        vm.prank(alice);
        pad.buy{value: (500e6 * 2e8)}(fine, 0, alice, type(uint256).max);
        vm.expectRevert(bytes("plugin broken"));
        pad.collectCreatorFees(bad);
        uint256 fineOwed = pad.pendingCreatorFees(fine);
        assertEq(pad.collectCreatorFees(fine), fineOwed);
        assertEq(good.received(fine), fineOwed);

        // The bad token graduates regardless, and its accrued fees stay collectable later
        _graduate(bad);
        vm.expectRevert(bytes("plugin broken"));
        pad.collectCreatorFees(bad);
        assertGt(pad.pendingCreatorFees(bad), 0);
        _assertSolvent();
    }

    function test_collect_unknownTokenReverts() public {
        vm.expectRevert(IMintMarkLaunchpad.UnknownToken.selector);
        pad.collectCreatorFees(address(0x1234));
    }

    function test_collect_zeroFeeTokenReturnsZero() public {
        address token = _create(0, creatorWallet);
        vm.prank(alice);
        pad.buy{value: (100e6 * 2e8)}(token, 0, alice, type(uint256).max);
        assertEq(pad.collectCreatorFees(token), 0);
    }

    function test_plugin_cannotBeZeroOrTheLaunchpad() public {
        vm.startPrank(alice);
        vm.expectRevert(IMintMarkLaunchpad.InvalidPlugin.selector);
        pad.createToken("Zero", "ZERO", "", 100, address(0), "", 0, type(uint256).max);
        vm.expectRevert(IMintMarkLaunchpad.InvalidPlugin.selector);
        pad.createToken("Self", "SELF", "", 100, address(pad), "", 0, type(uint256).max);
        vm.stopPrank();
    }

    function test_creatorFeesAccrueToTheirOwnTokenOnly() public {
        address a = _create(100, creatorWallet);
        address b = _create(900, alice);
        vm.prank(carol);
        pad.buy{value: (1_000e6 * 2e8)}(a, 0, carol, type(uint256).max);
        assertEq(pad.pendingCreatorFees(a), (1_000e6 * 2e8) * 100 / BPS);
        assertEq(pad.pendingCreatorFees(b), 0);
        vm.prank(carol);
        pad.buy{value: (1_000e6 * 2e8)}(b, 0, carol, type(uint256).max);
        assertEq(pad.pendingCreatorFees(a), (1_000e6 * 2e8) * 100 / BPS);
        assertEq(pad.pendingCreatorFees(b), (1_000e6 * 2e8) * 900 / BPS);
        _assertSolvent();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3 — onLaunch
    // ═══════════════════════════════════════════════════════════════════════════

    function test_onLaunch_runsAfterRegistrationAndBeforeTheFirstBuy() public {
        ExactPlugin plugin = new ExactPlugin(pad);
        vm.prank(alice);
        address token = pad.createToken{value: (500e6 * 2e8)}("Hooked", "HOOK", "", 300, address(plugin), hex"c0ffee", 0, type(uint256).max);
        assertEq(plugin.launches(), 1);
        assertEq(plugin.lastToken(), token);
        assertEq(plugin.lastCreator(), alice);
        assertEq(plugin.lastData(), hex"c0ffee");
        assertTrue(plugin.curveRegisteredAtLaunch(), "the curve (plugin, creator, pair) was registered");
        assertEq(plugin.soldAtLaunch(), 0, "the first buy had not run");
        assertEq(plugin.creatorBalanceAtLaunch(), 0, "the creator held nothing yet");
        assertGt(IERC20(token).balanceOf(alice), 0, "then the first buy ran");
    }

    function test_onLaunch_revertRevertsTheLaunch() public {
        MisbehavingPlugin plugin = new MisbehavingPlugin();
        plugin.setRevertOnLaunch(true);
        uint256 before = pad.tokensLength();
        vm.prank(alice);
        vm.expectRevert(bytes("onLaunch refuses"));
        pad.createToken("No", "NO", "", 300, address(plugin), "", 0, type(uint256).max);
        assertEq(pad.tokensLength(), before);
    }

    /// @dev A plugin that does not declare the interface gets no onLaunch, so it takes no pluginData: with empty data it
    ///      launches with no hooks, and any data reverts DataForNonPlugin (it would be dropped: a mistyped address).
    function test_onLaunch_skippedForPluginsThatDoNotDeclareTheInterface() public {
        HooklessRecorder hookless = new HooklessRecorder();
        LyingPlugin liar = new LyingPlugin();
        vm.startPrank(alice);
        pad.createToken{value: (10e6 * 2e8)}("A", "A", "", 100, address(hookless), "", 0, type(uint256).max);
        pad.createToken{value: (10e6 * 2e8)}("B", "B", "", 100, address(liar), "", 0, type(uint256).max);
        pad.createToken{value: (10e6 * 2e8)}("C", "C", "", 100, bob, "", 0, type(uint256).max); // an EOA
        vm.expectRevert(IMintMarkLaunchpad.DataForNonPlugin.selector);
        pad.createToken{value: (10e6 * 2e8)}("A", "A", "", 100, address(hookless), "data", 0, type(uint256).max);
        vm.expectRevert(IMintMarkLaunchpad.DataForNonPlugin.selector);
        pad.createToken{value: (10e6 * 2e8)}("B", "B", "", 100, address(liar), "data", 0, type(uint256).max);
        vm.expectRevert(IMintMarkLaunchpad.DataForNonPlugin.selector);
        pad.createToken{value: (10e6 * 2e8)}("C", "C", "", 100, bob, "data", 0, type(uint256).max);
        vm.stopPrank();
        assertEq(hookless.hookCalls(), 0);
        assertEq(liar.hookCalls(), 0);
    }

    function test_tokenCreatedEvent() public {
        address predicted = vm.computeCreateAddress(address(pad), vm.getNonce(address(pad)));
        address predictedPool = migrator.poolFor(predicted);
        vm.expectEmit(true, true, true, true, address(pad));
        emit TokenCreated(predicted, alice, creatorWallet, predictedPool, 420, "Evt", "EVT", "ipfs://e");
        vm.prank(alice);
        pad.createToken("Evt", "EVT", "ipfs://e", 420, creatorWallet, "", 0, type(uint256).max);
    }




    // ═══════════════════════════════════════════════════════════════════════════
    // 4 — Graduation through the migrator into the DEX pool
    // ═══════════════════════════════════════════════════════════════════════════

    function test_graduation_seedsTheDexPoolAndLocksTheLp() public {
        address token = _create(300, creatorWallet);
        MockPair pool = _poolOf(token);
        assertEq(address(pool).code.length, 0, "the pool does not even exist before graduation");
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, type(uint256).max);
        (uint112 r0, uint112 r1,) = pool.getReserves();
        (uint256 reserveToken, uint256 reserveWeth) = pool.token0() == token ? (r0, r1) : (r1, r0);
        assertEq(reserveToken, POOL_SUPPLY);
        assertEq(reserveWeth, weth.balanceOf(address(pool)));
        assertEq(reserveWeth, uint256(pad.curves(token).virtualEth) - VIRTUAL_ETH_0, "seed = the curve's raise");
        assertEq(pool.balanceOf(DEAD) + 1000, pool.totalSupply(), "all LP but the mock's minimum locked at DEAD");
        assertGe(pool.balanceOf(DEAD), 1000);
        assertEq(IERC20(token).balanceOf(address(pad)), 0);
        assertEq(IERC20(token).allowance(address(pad), address(migrator)), 0, "no allowance left behind");
        _assertSolvent();
    }

    function test_graduation_brokenDexParksLiquidityInAVaultAndRetryWorks() public {
        address token = _create(300, creatorWallet);
        dexFactory.setMintBroken(true);
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, type(uint256).max);
        assertTrue(pad.isGraduated(token), "the sell-out buy still graduated");
        address vault = ILaunchToken(token).vault();
        assertTrue(vault != address(0), "liquidity parked in a vault");
        assertEq(IERC20(token).balanceOf(vault), POOL_SUPPLY);
        assertGt(vault.balance, 0);
        assertEq(IERC20(token).balanceOf(address(pad)), 0);
        _assertSolvent(); // the curve's float left with the graduation

        // Anyone retries once the DEX works again
        dexFactory.setMintBroken(false);
        vm.prank(mallory);
        address pool = GraduationVault(payable(vault)).migrate();
        assertEq(pool, pad.poolOf(token));
        assertEq(IERC20(token).balanceOf(pool), POOL_SUPPLY);
        assertEq(vault.balance, 0);
        assertEq(MockPair(pool).balanceOf(DEAD) + 1000, MockPair(pool).totalSupply());
    }

    function test_graduation_gasBurningDexCannotBlockTheSellOut() public {
        address token = _create(0, creatorWallet);
        dexFactory.setMintBurnsGas(true);
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, type(uint256).max);
        assertTrue(pad.isGraduated(token));
        assertTrue(ILaunchToken(token).vault() != address(0), "the capped migration failed into the vault");
        _assertSolvent();
    }








    // ═══════════════════════════════════════════════════════════════════════════
    // 6 — Views return zero values for unknown tokens (plugins rely on this)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_liteViews() public {
        address unknown = address(0xBEEF);
        assertEq(pad.pluginOf(unknown), address(0));
        assertEq(pad.creatorOf(unknown), address(0));
        assertEq(pad.creatorFeeBpsOf(unknown), 0);
        assertEq(pad.poolOf(unknown), address(0));
        assertFalse(pad.isGraduated(unknown));
        assertEq(pad.virtualEthOf(unknown), 0);
        assertEq(pad.pendingCreatorFees(unknown), 0);

        vm.prank(alice);
        address token = pad.createToken("V", "V", "", 333, bob, "", 0, type(uint256).max);
        assertEq(pad.pluginOf(token), bob);
        assertEq(pad.creatorOf(token), alice);
        assertEq(pad.creatorFeeBpsOf(token), 333);
        assertEq(pad.poolOf(token), migrator.poolFor(token));
        assertFalse(pad.isGraduated(token));
        assertEq(pad.virtualEthOf(token), VIRTUAL_ETH_0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7 — Requirements from the plugins build
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Hook-or-plain is decided once at launch: a plugin that stops declaring the interface (an upgraded proxy)
    ///      is still paid through onFees, so every unit it receives is credited to the token.
    function test_hookDecisionIsStored_pluginThatStopsDeclaringStillGetsOnFees() public {
        FlippablePlugin plugin = new FlippablePlugin(true);
        address token = _create(500, address(plugin));
        assertTrue(pad.curves(token).pluginHooks);
        assertEq(plugin.launches(), 1);
        uint256 owed = _accrue(token, (1_000e6 * 2e8));
        plugin.setDeclares(false);
        pad.collectCreatorFees(token);
        assertEq(plugin.feeCalls(), 1, "still paid through onFees");
        assertEq(plugin.credited(token), owed, "and credited to the token");
        assertEq(address(plugin).balance, owed);
        _assertSolvent();
    }

    /// @dev ...and a plain address that starts declaring later stays plain: it never had onLaunch for this token, so
    ///      onFees would refuse it and strand the fees.
    function test_hookDecisionIsStored_plainAddressThatStartsDeclaringStaysPlain() public {
        FlippablePlugin plugin = new FlippablePlugin(false);
        address token = _create(500, address(plugin));
        assertFalse(pad.curves(token).pluginHooks);
        assertEq(plugin.launches(), 0, "no onLaunch for a plain address");
        uint256 owed = _accrue(token, (1_000e6 * 2e8));
        plugin.setDeclares(true);
        pad.collectCreatorFees(token);
        assertEq(plugin.feeCalls(), 0, "no onFees without onLaunch");
        assertEq(address(plugin).balance, owed, "a plain transfer");
        _assertSolvent();
    }

    function test_pluginHooksFlagPerKindOfPlugin() public {
        assertFalse(pad.curves(_create(100, creatorWallet)).pluginHooks, "EOA");
        assertTrue(pad.curves(_create(100, address(new ExactPlugin(pad)))).pluginHooks, "ERC-165 plugin");
        assertFalse(pad.curves(_create(100, address(new HooklessRecorder()))).pluginHooks, "no ERC-165");
        assertFalse(pad.curves(_create(100, address(new LyingPlugin()))).pluginHooks, "claims 0xffffffff");
        assertFalse(pad.curves(_create(100, address(new GasGuzzlerPlugin()))).pluginHooks, "probe runs out of gas");
    }

    /// @dev onLaunch gets all remaining gas: a configuration as heavy as a full Combo (~1.3M) plus a sell-out first buy
    ///      and graduation fit in one 5M-gas transaction.
    function test_heavyOnLaunchWithASellOutFirstBuyFitsIn11MGas() public {
        HeavyLaunchPlugin heavy = new HeavyLaunchPlugin(60); // 60 fresh storage slots: ~1.33M gas
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        address token = pad.createToken{value: 40 ether, gas: 11_000_000}("Heavy", "HVY", "", 1000, address(heavy), "", 0, type(uint256).max);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("gas: create + 1.3M onLaunch + sell-out + graduation", used);
        assertTrue(pad.isGraduated(token));
        assertEq(heavy.store(59), 60, "the whole configuration was written");
        assertGt(heavy.gasAtLaunch(), 1_400_000, "onLaunch had room to spare");
        _assertSolvent();
    }

    function test_buy_pullsExactlyUsdcSpentAndDeliversToTo() public {
        address token = _create(300, creatorWallet);
        // A normal buy: bob pays, carol receives
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        (uint256 out, uint256 spent) = pad.buy{value: (500e6 * 2e8)}(token, 0, carol, type(uint256).max);
        assertEq(spent, (500e6 * 2e8));
        assertEq(bobBefore - bob.balance, spent);
        assertEq(IERC20(token).balanceOf(carol), out);
        assertEq(IERC20(token).balanceOf(bob), 0);
        // The sell-out buy: offered far more than needed, pulls exactly ethSpent, delivers the remainder to carol
        uint256 remaining = CURVE_SUPPLY - pad.curves(token).tokensSold;
        bobBefore = bob.balance;
        uint256 carolBefore = IERC20(token).balanceOf(carol);
        vm.prank(bob);
        (out, spent) = pad.buy{value: (1_000_000e6 * 2e8)}(token, 0, carol, type(uint256).max);
        assertEq(out, remaining, "the true tokensOut");
        assertLt(spent, (1_000_000e6 * 2e8));
        assertEq(bobBefore - bob.balance, spent, "pulled exactly what it returned");
        assertEq(IERC20(token).balanceOf(carol) - carolBefore, out);
        assertTrue(pad.isGraduated(token), "graduated inside the sell-out buy");
        _assertSolvent();
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // 8 — End to end: a Distribute-to-holders plugin pays holders through the token
    // ═══════════════════════════════════════════════════════════════════════════

    function test_distributePluginEndToEnd() public {
        DistributePlugin plugin = new DistributePlugin();
        address token = _create(1000, address(plugin));
        vm.prank(alice);
        pad.buy{value: (3_000e6 * 2e8)}(token, 0, alice, type(uint256).max);
        vm.prank(bob);
        pad.buy{value: (1_000e6 * 2e8)}(token, 0, bob, type(uint256).max);
        uint256 owed = pad.pendingCreatorFees(token);
        pad.collectCreatorFees(token);
        ILaunchToken t = ILaunchToken(token);
        assertEq(t.totalDistributed(), owed);
        // The token streams what it is given over its DRIP_PERIOD: nothing is claimable at once, all of it a day on.
        assertEq(t.claimable(alice), 0);
        vm.warp(vm.getBlockTimestamp() + t.DRIP_PERIOD());
        uint256 a = t.claimable(alice);
        uint256 b = t.claimable(bob);
        assertLe(a + b, owed);
        assertApproxEqAbs(a + b, owed, 2);
        // pro-rata to balances
        assertApproxEqRel(a * IERC20(token).balanceOf(bob), b * IERC20(token).balanceOf(alice), 1e12);
        assertEq(t.claimable(address(pad)), 0, "the curve inventory never earns");
        uint256 aliceBefore = alice.balance;
        vm.prank(mallory);
        assertEq(t.claimFor(alice), a, "anyone can claim for a holder");
        assertEq(alice.balance, aliceBefore + a);
        _assertSolvent();
    }
}

/// @notice The creator's cap on the launch fee: the admin can raise the fee, but not above what a pending launch agreed to.
contract LaunchFeeGuardTest is MintMarkBase {
    function setUp() public override {
        super.setUp();
        vm.prank(setter);
        pad.setLaunchFee((5e6 * 2e8));
    }

    function test_createToken_revertsWhenLaunchFeeRaisedAboveTheCreatorsMax() public {
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.LaunchFeeAboveMax.selector);
        pad.createToken{value: (5e6 * 2e8)}("Coin", "COIN", "ipfs://x", 0, alice, "", 0, (1e6 * 2e8));
    }

    function test_createToken_revertsWhenValueDoesNotCoverTheFee() public {
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.InsufficientValue.selector);
        pad.createToken{value: (5e6 * 2e8) - 1}("Coin", "COIN", "ipfs://x", 0, alice, "", 0, (5e6 * 2e8));
    }

    function test_createToken_chargesExactlyTheCurrentFeeWhenWithinTheMax() public {
        uint256 before = alice.balance;
        uint256 pendingBefore = pad.pendingFees();
        vm.prank(alice);
        pad.createToken{value: (5e6 * 2e8)}("Coin", "COIN", "ipfs://x", 0, alice, "", 0, (5e6 * 2e8));
        assertEq(before - alice.balance, (5e6 * 2e8));
        assertEq(pad.pendingFees() - pendingBefore, (5e6 * 2e8));
    }

    function test_createToken_zeroMaxWorksOnlyWhileTheFeeIsZero() public {
        vm.prank(setter);
        pad.setLaunchFee(0);
        vm.prank(alice);
        pad.createToken("Coin", "COIN", "ipfs://x", 0, alice, "", 0, 0);

        vm.prank(setter);
        pad.setLaunchFee(1);
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.LaunchFeeAboveMax.selector);
        pad.createToken{value: 1}("Coin2", "COIN2", "ipfs://y", 0, alice, "", 0, 0);
    }

    function testFuzz_createToken_neverChargesAboveTheMax(uint96 fee, uint96 maxFee) public {
        fee = uint96(bound(fee, 0, pad.MAX_LAUNCH_FEE()));
        vm.prank(setter);
        pad.setLaunchFee(fee);
        uint256 before = alice.balance;
        vm.prank(alice);
        if (fee > maxFee) {
            vm.expectRevert(IMintMarkLaunchpad.LaunchFeeAboveMax.selector);
            pad.createToken{value: fee}("Coin", "COIN", "ipfs://x", 0, alice, "", 0, maxFee);
        } else {
            pad.createToken{value: fee}("Coin", "COIN", "ipfs://x", 0, alice, "", 0, maxFee);
            assertLe(before - alice.balance, maxFee);
        }
    }
}
