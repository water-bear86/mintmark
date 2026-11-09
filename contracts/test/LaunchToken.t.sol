// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "./launchpad/MintMarkBase.sol";

/// @notice A bot doing everything in one transaction against a token whose curve inventory approved it: buy (a
///         transfer out of the inventory), claim, sell (a transfer back).
contract OneTxSniper {
    function snipe(LaunchToken token, address inventory, uint256 tokens) external returns (uint256 claimed) {
        token.transferFrom(inventory, address(this), tokens);
        claimed = token.claim();
        token.transfer(inventory, tokens);
    }
}

contract RejectingHolder {
    bool public accept;

    function setAccept(bool v) external {
        accept = v;
    }

    receive() external payable {
        require(accept, "rejects ETH");
    }
}

/// @notice LaunchToken v2 in isolation: this test contract deploys it, so it is the token's launchpad (the curve
///         inventory, excluded from dividends). A transfer out of it stands in for a curve buy, a transfer back or a
///         pull for a sell.
/// @dev Time is read with vm.getBlockTimestamp(), never block.timestamp: under via-IR the optimizer may re-read
///      TIMESTAMP where the source cached it, which is wrong after a vm.warp in the same test.
contract LaunchTokenTest is Test {
    uint256 constant TOTAL = 1_000_000_000e18;
    uint256 constant PERIOD = 24 hours;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event DividendsDistributed(address indexed from, uint256 amount);
    event DividendClaimed(address indexed holder, uint256 amount);

    LaunchToken token;
    address pool = makeAddr("pool");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address payer = makeAddr("payer");

    function setUp() public {
        token = new LaunchToken("Dividend", "DIV");
        token.initPool(pool);
        vm.deal(payer, type(uint128).max);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    address internal puller = makeAddr("puller");

    function _give(address to, uint256 amount) internal {
        token.transfer(to, amount); // from the launchpad (this)
    }

    /// @dev The migrator mechanics in miniature: the launchpad approves, someone else pulls into the pool.
    function _seedPool(uint256 amount) internal {
        token.approve(puller, amount);
        vm.prank(puller);
        token.transferFrom(address(this), pool, amount);
    }

    function _distribute(uint256 amount) internal {
        vm.prank(payer);
        token.distribute{value: amount}();
    }

    /// @dev A holder gets the exact time-weighted amount or up to `slack` units less, never more.
    function _assertFloored(uint256 actual, uint256 exact, uint256 slack) internal pure {
        assertLe(actual, exact, "never more than the exact share");
        assertLe(exact - actual, slack, "rounding only");
    }

    function _assertFloored(uint256 actual, uint256 exact) internal pure {
        _assertFloored(actual, exact, 1);
    }

    /// @dev The eligible supply the token tracks, against the formula it replaces.
    function _assertEligibleIsTheFormula() internal view {
        uint256 formula = token.totalSupply() - token.balanceOf(address(this)) - token.balanceOf(pool) - token.balanceOf(DEAD);
        assertEq(token.eligibleSupply(), formula < 1e18 ? 0 : formula, "tracked eligible == the formula");
    }

    // ─── Supply, roles, burn ─────────────────────────────────────────────────

    function test_initPoolAndSetVault_launchpadOnlyOnce() public {
        vm.prank(alice);
        vm.expectRevert(ILaunchToken.OnlyLaunchpad.selector);
        token.initPool(alice);
        vm.expectRevert(ILaunchToken.PoolAlreadySet.selector);
        token.initPool(alice);
        vm.prank(alice);
        vm.expectRevert(ILaunchToken.OnlyLaunchpad.selector);
        token.setVault(alice);
        token.setVault(carol);
        vm.expectRevert(ILaunchToken.VaultAlreadySet.selector);
        token.setVault(bob);
    }

    function test_poolLock_onlySeedingPullsUnlock() public {
        _give(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(ILaunchToken.PoolLocked.selector);
        token.transfer(pool, 1);

        // Even the launchpad's own plain transfer is refused (review #1 H1: that is an ordinary buy payout)
        vm.expectRevert(ILaunchToken.PoolLocked.selector);
        token.transfer(pool, 1);

        // The migrator-style pull out of the launchpad unlocks the pool for good
        _seedPool(1);
        assertTrue(token.poolUnlocked());
        vm.prank(alice);
        token.transfer(pool, 1);
        assertEq(token.balanceOf(pool), 2);
    }

    function test_poolLock_vaultDepositUnlocksToo() public {
        token.setVault(carol);
        _give(carol, 10e18);
        _give(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(ILaunchToken.PoolLocked.selector);
        token.transfer(pool, 1);
        vm.prank(carol);
        token.transfer(pool, 5e18);
        assertTrue(token.poolUnlocked());
        vm.prank(alice);
        token.transfer(pool, 1);
    }

    function test_pull_permissionsAndDestinations() public {
        _give(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(ILaunchToken.OnlyLaunchpad.selector);
        token.pull(alice, bob, 1);

        // The launchpad pulls into itself only
        vm.expectRevert(ILaunchToken.InvalidPullTarget.selector);
        token.pull(alice, bob, 1);
        token.pull(alice, address(this), 10e18);
        assertEq(token.balanceOf(alice), 90e18);
    }


    function test_fixedSupplyAtTheLaunchpad() public view {
        assertEq(token.totalSupply(), TOTAL);
        assertEq(token.balanceOf(address(this)), TOTAL);
        assertEq(token.launchpad(), address(this));
        assertEq(token.pool(), pool);
        assertEq(token.vault(), address(0));
        assertEq(token.decimals(), 18);
        assertEq(token.MIN_ELIGIBLE_SUPPLY(), 1e18);
        assertEq(token.DRIP_PERIOD(), 24 hours);
        assertEq(token.eligibleSupply(), 0);
        assertFalse(token.poolUnlocked());
    }

    function test_burnReducesSupply() public {
        _give(alice, 1_000e18);
        vm.prank(alice);
        token.burn(400e18);
        assertEq(token.totalSupply(), TOTAL - 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.eligibleSupply(), 600e18);
        vm.prank(alice);
        vm.expectRevert();
        token.burn(600e18 + 1);
    }




    function test_exclusions() public view {
        assertTrue(token.isExcluded(address(this)));
        assertTrue(token.isExcluded(pool));
        assertTrue(token.isExcluded(DEAD));
        assertTrue(token.isExcluded(address(0)));
        assertFalse(token.isExcluded(alice));
        
        assertFalse(token.isExcluded(address(token)));
    }

    /// @dev Contracts (plugins among them) hold, transfer and burn like anyone else; nothing calls back into them.
    function test_contractsHoldAndBurnFreely() public {
        address plugin = address(new HooklessRecorder());
        _give(plugin, 500e18);
        vm.startPrank(plugin);
        token.transfer(alice, 100e18);
        token.burn(400e18);
        vm.stopPrank();
        assertEq(token.balanceOf(plugin), 0);
        assertEq(token.totalSupply(), TOTAL - 400e18);
        assertEq(HooklessRecorder(payable(plugin)).hookCalls(), 0);
    }

    // ─── Streaming ───────────────────────────────────────────────────────────

    /// @dev A distribution is paid out over DRIP_PERIOD: nothing at once, a quarter by 6h, all by 24h, pro-rata.
    function test_distribute_streamsOverTheDripPeriod() public {
        _give(alice, 300e18);
        _give(bob, 100e18);
        uint256 t0 = _now();
        vm.expectEmit(true, false, false, true, address(token));
        emit DividendsDistributed(payer, (400e6 * 2e8));
        _distribute((400e6 * 2e8));
        assertEq(address(token).balance, (400e6 * 2e8));
        assertEq(token.totalDistributed(), (400e6 * 2e8));
        assertEq(token.streamEnd(), t0 + PERIOD);
        assertEq(token.lastAccrual(), t0);
        assertEq(token.streamRate(), (400e6 * 2e8) / PERIOD);
        assertApproxEqAbs(token.undistributed(), (400e6 * 2e8), 1);
        assertEq(token.claimable(alice), 0, "nothing at once");
        assertEq(token.claimable(bob), 0);

        vm.warp(t0 + 6 hours);
        _assertFloored(token.claimable(alice), (75e6 * 2e8));
        _assertFloored(token.claimable(bob), (25e6 * 2e8));
        assertApproxEqAbs(token.undistributed(), (300e6 * 2e8), 1);

        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (300e6 * 2e8));
        _assertFloored(token.claimable(bob), (100e6 * 2e8));
        assertEq(token.claimable(address(this)), 0, "the launchpad's 999,999,600 tokens earn nothing");
        assertEq(token.undistributed(), 0);

        vm.warp(t0 + 3 days);
        _assertFloored(token.claimable(alice), (300e6 * 2e8));
        _assertFloored(token.claimable(bob), (100e6 * 2e8));
    }

    function test_claim_paysTheHolderAndClaimForNeverPaysTheCaller() public {
        _give(alice, 300e18);
        _give(bob, 100e18);
        _distribute((400e6 * 2e8));
        vm.warp(_now() + PERIOD);

        uint256 aliceShare = token.claimable(alice);
        vm.expectEmit(true, false, false, true, address(token));
        emit DividendClaimed(alice, aliceShare);
        vm.prank(alice);
        assertEq(token.claim(), aliceShare);
        assertEq(alice.balance, aliceShare);
        assertEq(token.claimed(alice), aliceShare);
        assertEq(token.claimable(alice), 0);
        vm.prank(alice);
        assertEq(token.claim(), 0, "nothing twice");

        uint256 bobShare = token.claimable(bob);
        vm.prank(carol);
        assertEq(token.claimFor(bob), bobShare);
        assertEq(bob.balance, bobShare);
        assertEq(carol.balance, 0);
        assertLe(address(token).balance, 2, "only rounding dust stays behind");
    }

    function test_distribute_zeroIsANoop() public {
        _give(alice, 1e18);
        vm.recordLogs();
        _distribute(0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token.totalDistributed(), 0);
        assertEq(token.streamEnd(), 0);
    }

    /// @dev distribute never reverts for lack of eligible supply (nobody, only excluded holders, or under one whole
    ///      token): it pulls, and the stream waits.
    function test_distribute_withNoEligibleSupplyDoesNotRevert() public {
        _distribute((1e6 * 2e8));
        _seedPool(1_000e18); // the seeding pull (unlocks the pool; still excluded)
        _give(DEAD, 1_000e18);
        _give(alice, 1e18 - 1);
        assertEq(token.eligibleSupply(), 0);
        _distribute((1e6 * 2e8));
        assertEq(token.totalDistributed(), (2e6 * 2e8));
        assertEq(address(token).balance, (2e6 * 2e8));
    }

    /// @dev Pulls exactly `amount`, with or without eligible supply.
    function testFuzz_distributePullsExactly(uint256 held, uint256 amount) public {
        held = bound(held, 0, 1e21);
        amount = bound(amount, 0, 1e15);
        if (held > 0) _give(alice, held);
        uint256 payerBefore = payer.balance;
        _distribute(amount);
        assertEq(payerBefore - payer.balance, amount);
        assertEq(address(token).balance, amount);
        assertEq(token.totalDistributed(), amount);
    }

    /// @dev A second amount joins what the stream still owes, and the end moves to the amount-weighted average of
    ///      the old end and a full period from now: 50 owed (ending 24h) + 100 new (36h) end at 32h. Everything is
    ///      paid by then.
    function test_distribute_aSecondAmountMovesTheEndToTheWeightedAverage() public {
        _give(alice, 1e18);
        uint256 t0 = _now();
        _distribute((100e6 * 2e8));
        vm.warp(t0 + 12 hours);
        _distribute((100e6 * 2e8));
        assertEq(token.streamEnd(), t0 + 32 hours);
        assertApproxEqAbs(token.undistributed(), (150e6 * 2e8), 1);
        vm.warp(t0 + 32 hours);
        _assertFloored(token.claimable(alice), (200e6 * 2e8), 2);
        assertEq(token.undistributed(), 0);
    }

    /// @dev Dust cannot slow a stream: a 1-unit distribution every hour leaves a 1,000,000 USDC stream's end where it
    ///      was (the weighted end rounds down), and its holder earns on the original line.
    function test_distribute_dustDoesNotSlowTheStream() public {
        _give(alice, 1e18);
        uint256 t0 = _now();
        _distribute((1_000_000e6 * 2e8));
        for (uint256 h = 1; h < 24; ++h) {
            vm.warp(t0 + h * 1 hours);
            _distribute(1);
            assertEq(token.streamEnd(), t0 + PERIOD, "dust moves the end by 0");
            _assertFloored(token.claimable(alice), ((1_000_000e6 * 2e8) * h) / 24 + h, h + 1);
        }
        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (1_000_000e6 * 2e8) + 23, 2);
    }

    // ─── Time-weighting: a holder earns only while it holds ──────────────────

    /// @dev Alice holds from the start; Bob buys as much at 6h. Alice gets all of the first 6 hours and half of the
    ///      other 18; Bob half of those 18 only.
    function test_aBuyerEarnsOnlyFromItsBuy() public {
        _give(alice, 100e18);
        uint256 t0 = _now();
        _distribute((96e6 * 2e8)); // 4 USDC an hour
        vm.warp(t0 + 6 hours);
        _give(bob, 100e18);
        assertEq(token.claimable(bob), 0, "bought just now");
        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (24e6 * 2e8) + (36e6 * 2e8));
        _assertFloored(token.claimable(bob), (36e6 * 2e8));
    }

    /// @dev Alice holds A throughout; Bob holds B from t1 to t2 and then sells. Each gets exactly the time-weighted
    ///      share: for every second, the stream split by what each held that second.
    function testFuzz_overlappingHoldersGetTimeWeightedShares(
        uint96 aRaw,
        uint96 bRaw,
        uint32 t1Raw,
        uint32 t2Raw,
        uint64 amountRaw
    ) public {
        uint256 a = bound(aRaw, 1e18, 1e26);
        uint256 b = bound(bRaw, 1e18, 1e26);
        uint256 t1 = bound(t1Raw, 0, PERIOD);
        uint256 t2 = bound(t2Raw, t1, PERIOD);
        uint256 amount = bound(amountRaw, (1e6 * 2e8), 1e15);
        _give(alice, a);
        uint256 t0 = _now();
        _distribute(amount);

        vm.warp(t0 + t1);
        _give(bob, b);
        vm.warp(t0 + t2);
        vm.prank(bob);
        token.transfer(address(this), b); // Bob sells everything
        vm.warp(t0 + PERIOD);

        // Exact shares, each rounded down once: alice alone for PERIOD - shared seconds, both for `shared` seconds.
        uint256 shared = t2 - t1;
        uint256 bobExact = Math.mulDiv(amount, shared * b, PERIOD * (a + b));
        uint256 aliceExact = Math.mulDiv(amount, (PERIOD - shared) * (a + b) + shared * a, PERIOD * (a + b));
        _assertFloored(token.claimable(bob), bobExact, 2);
        _assertFloored(token.claimable(alice), aliceExact, 2);
    }

    // ─── The one-transaction snipe ───────────────────────────────────────────

    /// @dev Whatever has been distributed and however long nobody touched the token, and whether or not anyone else
    ///      holds: buying, claiming and selling in one transaction earns exactly 0. (With other holders, what they
    ///      earned stays theirs.)
    function testFuzz_oneTransactionSnipeEarnsExactlyZero(uint64 amountRaw, uint32 idleRaw, bool othersHold, uint96 buyRaw)
        public
    {
        uint256 amount = bound(amountRaw, 1, 1e15);
        uint256 idle = bound(idleRaw, 0, 30 days);
        uint256 bought = bound(buyRaw, 1e18, 1e26);
        if (othersHold) _give(alice, 1e24);
        uint256 t0 = _now();
        _distribute(amount);
        vm.warp(t0 + idle);
        uint256 aliceBefore = token.claimable(alice);

        OneTxSniper sniper = new OneTxSniper();
        token.approve(address(sniper), bought);
        assertEq(sniper.snipe(token, address(this), bought), 0, "the snipe earns exactly 0");
        assertEq(address(sniper).balance, 0);
        assertEq(token.claimable(address(sniper)), 0);
        assertEq(token.claimable(alice), aliceBefore, "the holder's earnings are untouched");
    }

    /// @dev The review's case: a 10,000 USDC stream, everyone sells, a day passes, a bot buys one token, claims and
    ///      sells in one transaction. It gets 0; the stream was paused, not matured, and resumes for the next holder.
    function test_everyoneSoldADayPassedABotBuysOneTokenAndGetsNothing() public {
        _give(alice, 1_000e18);
        uint256 t0 = _now();
        _distribute((10_000e6 * 2e8));
        vm.warp(t0 + 1 hours);
        vm.prank(alice);
        token.transfer(address(this), 1_000e18); // everyone sells
        uint256 aliceEarned = token.claimable(alice);
        _assertFloored(aliceEarned, uint256((10_000e6 * 2e8)) / 24);
        uint256 owed = token.undistributed();

        vm.warp(t0 + 25 hours);
        OneTxSniper sniper = new OneTxSniper();
        token.approve(address(sniper), 1e18);
        assertEq(sniper.snipe(token, address(this), 1e18), 0);
        assertEq(token.undistributed(), owed, "nothing matured while nobody held");
        assertEq(token.streamEnd(), t0 + PERIOD + 24 hours, "paused for exactly the day nobody held");
        assertEq(token.claimable(alice), aliceEarned);
    }

    // ─── Pause while nobody holds ────────────────────────────────────────────

    /// @dev Alice earns 6 of 24 hours, then sells everything; ten hours pass with nobody holding. The stream pauses:
    ///      nothing accrues to anyone, and the end moves out by exactly the ten hours. Bob, buying then, earns the
    ///      remaining 18 hours by the moved end. Nothing leaks.
    function test_pause_shiftsTheEndByExactlyThePausedTimeAndNothingLeaks() public {
        _give(alice, 100e18);
        uint256 t0 = _now();
        _distribute((24e6 * 2e8));
        vm.warp(t0 + 6 hours);
        vm.prank(alice);
        token.transfer(address(this), 100e18);
        _assertFloored(token.claimable(alice), (6e6 * 2e8));
        assertEq(token.eligibleSupply(), 0);

        vm.warp(t0 + 16 hours);
        _assertFloored(token.claimable(alice), (6e6 * 2e8));
        assertApproxEqAbs(token.undistributed(), (18e6 * 2e8), 1);
        _give(bob, 50e18); // the accrual at this transfer moves the end out by the paused time
        assertEq(token.streamEnd(), t0 + PERIOD + 10 hours);
        assertEq(token.claimable(bob), 0);

        vm.warp(t0 + PERIOD + 10 hours);
        _assertFloored(token.claimable(bob), (18e6 * 2e8), 2);
        _assertFloored(token.claimable(alice), (6e6 * 2e8));
        assertLe(token.claimable(alice) + token.claimable(bob), (24e6 * 2e8));
        assertEq(token.undistributed(), 0);
    }

    /// @dev Under one whole eligible token the stream is paused, and eligibleSupply() reports 0.
    function test_pause_belowOneWholeEligibleToken() public {
        _give(alice, 1e18 - 1);
        uint256 t0 = _now();
        _distribute((24e6 * 2e8));
        vm.warp(t0 + 5 hours);
        assertEq(token.claimable(alice), 0);
        _give(bob, 1); // one whole eligible token: the stream resumes from here, 5 hours later
        assertEq(token.eligibleSupply(), 1e18);
        assertEq(token.streamEnd(), t0 + PERIOD + 5 hours);
        vm.warp(t0 + PERIOD + 5 hours);
        _assertFloored(token.claimable(alice) + token.claimable(bob), (24e6 * 2e8), 2);
    }

    // ─── Transfers, burns, pulls keep what was earned ────────────────────────

    function test_excludedAccountsNeverAccrue() public {
        _give(alice, 100e18);
        _seedPool(500e18);
        _give(DEAD, 500e18);
        _distribute((100e6 * 2e8));
        vm.warp(_now() + PERIOD);
        _assertFloored(token.claimable(alice), (100e6 * 2e8));
        assertEq(token.claimable(pool), 0);
        assertEq(token.claimable(DEAD), 0);
        assertEq(token.claimable(address(this)), 0);
        assertEq(token.claimFor(pool), 0);
        assertEq(token.claimFor(DEAD), 0);
        assertEq(token.claimFor(address(this)), 0);
    }

    function test_transferKeepsEarnedDividendsWithTheSender() public {
        _give(alice, 100e18);
        _give(bob, 100e18);
        uint256 t0 = _now();
        _distribute((200e6 * 2e8));
        vm.warp(t0 + 12 hours); // 100 paid so far, 50 each
        vm.prank(alice);
        token.transfer(carol, 100e18);
        _assertFloored(token.claimable(alice), (50e6 * 2e8));
        assertEq(token.claimable(carol), 0, "carol earned nothing yet");
        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (50e6 * 2e8));
        _assertFloored(token.claimable(carol), (50e6 * 2e8));
        _assertFloored(token.claimable(bob), (100e6 * 2e8));
    }

    function test_sendingToAnExcludedAddressStopsAccrual() public {
        _give(alice, 100e18);
        _give(bob, 100e18);
        uint256 t0 = _now();
        _distribute((200e6 * 2e8));
        vm.warp(t0 + 12 hours);
        vm.prank(alice);
        token.transfer(DEAD, 100e18);
        assertEq(token.eligibleSupply(), 100e18);
        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (50e6 * 2e8));
        _assertFloored(token.claimable(bob), (150e6 * 2e8));
        assertEq(token.claimable(DEAD), 0);
    }

    function test_burnKeepsEarnedAndShrinksTheBase() public {
        _give(alice, 100e18);
        _give(bob, 100e18);
        uint256 t0 = _now();
        _distribute((200e6 * 2e8));
        vm.warp(t0 + 12 hours);
        vm.prank(alice);
        token.burn(100e18);
        assertEq(token.eligibleSupply(), 100e18);
        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (50e6 * 2e8));
        _assertFloored(token.claimable(bob), (150e6 * 2e8));
    }

    function test_pullKeepsEarned() public {
        _give(alice, 100e18);
        _give(bob, 100e18);
        uint256 t0 = _now();
        _distribute((200e6 * 2e8));
        vm.warp(t0 + 12 hours);
        token.pull(alice, address(this), 100e18); // a curve sell
        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (50e6 * 2e8));
        _assertFloored(token.claimable(bob), (150e6 * 2e8));
        assertEq(token.claimable(address(this)), 0);
    }

    function test_selfTransferChangesNothing() public {
        _give(alice, 100e18);
        _give(bob, 300e18);
        uint256 t0 = _now();
        _distribute((400e6 * 2e8));
        vm.warp(t0 + 12 hours);
        vm.prank(alice);
        token.transfer(alice, 60e18);
        vm.warp(t0 + PERIOD);
        _assertFloored(token.claimable(alice), (100e6 * 2e8));
        _assertFloored(token.claimable(bob), (300e6 * 2e8));
    }

    function test_holderThatRejectsEthKeepsTheirClaim() public {
        RejectingHolder holder = new RejectingHolder();
        _give(address(holder), 100e18);
        _distribute((50e6 * 2e8));
        vm.warp(_now() + PERIOD);
        vm.expectRevert();
        token.claimFor(address(holder));
        _assertFloored(token.claimable(address(holder)), (50e6 * 2e8));
        holder.setAccept(true);
        _assertFloored(token.claimFor(address(holder)), (50e6 * 2e8));
    }

    /// @dev The minimum eligible supply bounds the per-share growth: even after distributions far larger than all
    ///      USDC in existence streamed to the smallest allowed base, moving the whole supply still works.
    function test_minimumEligibleSupplyKeepsTransfersSafe() public {
        _give(alice, 1e18); // the smallest base the stream runs on
        // 1e11 USDC per round (more than all USDC that exists), 20 rounds, each streamed out and claimed back
        for (uint256 i = 0; i < 20; i++) {
            _distribute(1e17);
            vm.warp(_now() + PERIOD);
            vm.prank(alice);
            token.claim();
        }
        // the seeding pull unlocks the pool, then the launchpad moves (nearly) the whole supply around
        _seedPool(1);
        token.transfer(bob, TOTAL - 1e18 - 1);
        vm.prank(bob);
        token.transfer(carol, TOTAL - 1e18 - 1);
        vm.prank(carol);
        token.transfer(pool, TOTAL - 1e18 - 1);
        assertEq(token.balanceOf(pool), TOTAL - 1e18);
        assertEq(token.claimable(bob), 0);
        assertEq(token.claimable(carol), 0);
        assertLe(token.claimed(alice), 20 * 1e17);
        assertGe(token.claimed(alice), 20 * 1e17 - 40);
    }

    // ─── Eligible supply is tracked exactly ──────────────────────────────────

    /// @dev Across buys, sells (pulls into the launchpad and, after graduation, into the pool), transfers, sends to
    ///      0x…dEaD and burns, the tracked eligible supply equals the formula it replaces.
    function test_eligibleSupplyTracksTheFormulaThroughEveryFlow() public {
        _give(alice, 500e18);
        _assertEligibleIsTheFormula();
        _give(bob, 250e18);
        vm.prank(alice);
        token.transfer(carol, 100e18);
        _assertEligibleIsTheFormula();
        token.pull(bob, address(this), 50e18);
        _assertEligibleIsTheFormula();
        vm.prank(carol);
        token.transfer(DEAD, 30e18);
        _assertEligibleIsTheFormula();
        vm.prank(alice);
        token.burn(20e18);
        _assertEligibleIsTheFormula();
        _seedPool(200_000_000e18); // the graduation pull (excluded to excluded; unlocks the pool)
        _assertEligibleIsTheFormula();
        vm.prank(alice);
        token.transfer(pool, 80e18); // a pool sell
        _assertEligibleIsTheFormula();
        vm.prank(pool);
        token.transfer(bob, 40e18); // a pool buy (or an LP burn paying tokens out)
        _assertEligibleIsTheFormula();
        vm.prank(bob);
        token.transfer(pool, 10e18); // an LP deposit
        _assertEligibleIsTheFormula();
        vm.prank(DEAD);
        token.transfer(carol, 5e18); // excluded to eligible
        _assertEligibleIsTheFormula();
    }

    // ─── Conservation under random activity ──────────────────────────────────

    /// @dev Random distributions, transfers, burns, claims, pulls, sends to 0x…dEaD and time. After every step:
    ///      Σ claimable + Σ claimed <= Σ distributed; what is neither credited nor still streaming is rounding dust;
    ///      the token holds exactly what was distributed and not claimed; excluded accounts earn nothing; and the
    ///      tracked eligible supply is the formula.
    function testFuzz_dividendsNeverOverCredit(uint256 seed) public {
        address[4] memory holders = [alice, bob, carol, makeAddr("dave")];
        for (uint256 i = 0; i < holders.length; i++) {
            _give(holders[i], 1e24 + (uint256(keccak256(abi.encode(seed, i))) % 1e26));
        }
        uint256 distributions;
        for (uint256 step = 0; step < 40; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address a = holders[r % 4];
            address b = holders[(r >> 8) % 4];
            uint256 action = (r >> 16) % 8;
            uint256 amount = r >> 32;
            if (action == 0) {
                _distribute(amount % 1e13);
                distributions++;
            } else if (action == 1) {
                uint256 bal = token.balanceOf(a);
                vm.prank(a);
                token.transfer(b, bal == 0 ? 0 : amount % (bal + 1));
            } else if (action == 2) {
                uint256 bal = token.balanceOf(a);
                vm.prank(a);
                token.burn(bal == 0 ? 0 : amount % (bal + 1));
            } else if (action == 3) {
                vm.prank(b);
                token.claimFor(a);
            } else if (action == 4) {
                uint256 bal = token.balanceOf(a);
                token.pull(a, address(this), bal == 0 ? 0 : amount % (bal + 1));
            } else if (action == 5) {
                uint256 bal = token.balanceOf(a);
                token.pull(a, address(this), bal == 0 ? 0 : amount % (bal + 1));
            } else if (action == 6) {
                uint256 bal = token.balanceOf(a);
                vm.prank(a);
                token.transfer(DEAD, bal == 0 ? 0 : amount % (bal + 1));
            } else {
                vm.warp(_now() + amount % (2 * PERIOD));
            }

            uint256 credited;
            uint256 claimedSum;
            for (uint256 i = 0; i < holders.length; i++) {
                credited += token.claimable(holders[i]) + token.claimed(holders[i]);
                claimedSum += token.claimed(holders[i]);
            }
            assertLe(credited, token.totalDistributed(), "sum claimable + claimed <= sum distributed");
            assertLe(
                token.totalDistributed() - credited - token.undistributed(),
                distributions + holders.length + 1,
                "dust bound"
            );
            assertEq(address(token).balance, token.totalDistributed() - claimedSum);
            assertEq(token.claimable(pool) + token.claimable(DEAD) + token.claimable(address(this)), 0);
            _assertEligibleIsTheFormula();
        }
    }
}

/// @notice A bot doing a whole snipe through the real launchpad in one transaction: curve buy, collect the token's
///         pending creator fees to its plugin (which distributes them), claim, curve sell.
contract LaunchpadSniper {
    receive() external payable {}

    function snipe(MintMarkLaunchpad pad, address token, uint256 ethIn) external returns (uint256 claimed) {
        (uint256 tokens,) = pad.buy{value: ethIn}(token, 0, address(this), type(uint256).max);
        pad.collectCreatorFees(token);
        claimed = ILaunchToken(token).claim();
        pad.sell(token, tokens, 0, address(this), type(uint256).max);
    }
}

/// @notice The same token behaviour through the real launchpad: the curve inventory is excluded from the start,
///         the launch pool is registered before any buy, and sells pull through `pull`.
contract LaunchTokenThroughLaunchpadTest is MintMarkBase {
    function test_curveAndPoolSellsKeepDividendsExact() public {
        DistributePlugin plugin = new DistributePlugin();
        address t = _create(1000, address(plugin));
        ILaunchToken token = ILaunchToken(t);
        vm.prank(alice);
        pad.buy{value: (2_000e6 * 2e8)}(t, 0, alice, type(uint256).max);
        vm.prank(carol);
        pad.buy{value: (2_000e6 * 2e8)}(t, 0, carol, type(uint256).max);
        pad.collectCreatorFees(t); // distributes: streams over a day
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 aliceEarned = token.claimable(alice);
        uint256 carolEarned = token.claimable(carol);
        assertGt(aliceEarned, 0);

        // Curve sell (pull into the launchpad) keeps what was earned
        uint256 half = IERC20(t).balanceOf(alice) / 2;
        vm.prank(alice);
        pad.sell(t, half, 0, alice, type(uint256).max);
        assertEq(token.claimable(alice), aliceEarned);

        // Graduate, then a pool sell (pull into the pool) keeps it too
        _graduate(t);
        uint256 carolHalf = IERC20(t).balanceOf(carol) / 2;
        address poolAddr = pad.poolOf(t);
        vm.prank(carol);
        IERC20(t).transfer(poolAddr, carolHalf); // a pool sell: tokens enter the open pool
        assertEq(token.claimable(carol), carolEarned);

        // The next distribution ignores the launchpad and the pool
        pad.collectCreatorFees(t);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(token.claimable(address(pad)), 0);
        assertEq(token.claimable(pad.poolOf(t)), 0);
        uint256 credited = token.claimable(alice) + token.claimable(carol) + token.claimable(bob);
        assertLe(credited, token.totalDistributed());
        assertApproxEqAbs(credited, token.totalDistributed(), 5);
    }

    /// @dev Fees distributed before anyone holds do not revert: the stream waits, paused, and the first buyer earns
    ///      only from its buy, over the full period.
    function test_distributionBeforeAnyBuyWaitsForTheFirstHolder() public {
        address t = _create();
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(alice);
        ILaunchToken(t).distribute{value: (1e6 * 2e8)}();
        assertEq(ILaunchToken(t).totalDistributed(), (1e6 * 2e8));

        vm.warp(t0 + 5 days);
        vm.prank(bob);
        pad.buy{value: (100e6 * 2e8)}(t, 0, bob, type(uint256).max);
        assertEq(ILaunchToken(t).streamEnd(), t0 + 5 days + 1 days, "the stream waited");
        assertEq(ILaunchToken(t).claimable(bob), 0);
        vm.warp(t0 + 6 days);
        assertApproxEqAbs(ILaunchToken(t).claimable(bob), (1e6 * 2e8), 1);
    }

    /// @dev The whole snipe through the real launchpad in one transaction: a large pile of creator fees waits, a bot
    ///      buys on the curve, collects the pile to the Distribute plugin, claims and sells. It claims exactly 0.
    function test_oneTransactionSnipeThroughTheLaunchpadClaimsNothing() public {
        DistributePlugin plugin = new DistributePlugin();
        address t = _create(1000, address(plugin));
        vm.prank(alice);
        pad.buy{value: (5_000e6 * 2e8)}(t, 0, alice, type(uint256).max); // creator fees accrue at the launchpad
        assertGt(pad.pendingCreatorFees(t), 0);
        vm.warp(vm.getBlockTimestamp() + 3 days);

        LaunchpadSniper sniper = new LaunchpadSniper();
        vm.deal(address(sniper), (10_000e6 * 2e8));
        assertEq(sniper.snipe(pad, t, (10_000e6 * 2e8)), 0, "the snipe claims exactly 0");
        assertEq(ILaunchToken(t).claimable(address(sniper)), 0);
        assertEq(IERC20(t).balanceOf(address(sniper)), 0);
    }
}
