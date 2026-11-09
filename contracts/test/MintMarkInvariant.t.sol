// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "./launchpad/MintMarkBase.sol";

// ═══════════════════════════════════════════════════════════════════════════════
// 1. Launchpad solvency under random curve trades, graduations, dividend activity and fee collections
//    across five tokens with different plugins.
// ═══════════════════════════════════════════════════════════════════════════════

contract SolvencyHandler is Test {
    MintMarkLaunchpad public pad;
    MisbehavingPlugin public flaky;
    address[] public tokens;
    address[] public actors;

    // Ghosts
    bool public ghostPullCheckFailed;
    uint256 public ghostCollectReverts;
    uint256 public ghostGraduations;
    mapping(address => uint256) public ghostPluginPaid; // what each token's collections moved out

    constructor(MintMarkLaunchpad _pad, MisbehavingPlugin _flaky, address[] memory _tokens, address[] memory _actors) {
        pad = _pad;
        flaky = _flaky;
        tokens = _tokens;
        actors = _actors;
        for (uint256 i = 0; i < _actors.length; i++) {
            vm.deal(_actors[i], 1_000_000 ether);
        }
    }

    function _token(uint256 w) internal view returns (address) {
        return tokens[w % tokens.length];
    }

    function _actor(uint256 a) internal view returns (address) {
        return actors[a % actors.length];
    }

    bool public ghostPoolRecipientAccepted; // review #1 H1: a buy delivered into the pool or the launchpad

    function curveBuy(uint256 w, uint256 a, uint256 amount) external {
        address t = _token(w);
        if (pad.isGraduated(t)) return;
        address who = _actor(a);
        amount = bound(amount, 1, 1.2 ether);
        vm.prank(who);
        try pad.buy{value: amount}(t, 0, who, type(uint256).max) {} catch {}
    }

    /// @dev Review #1 H1 attack: buys that name the pool or the launchpad as the recipient must always revert.
    function curveBuyToForbiddenRecipient(uint256 w, uint256 a, uint256 amount, bool toPool) external {
        address t = _token(w);
        if (pad.isGraduated(t)) return;
        address who = _actor(a);
        address to = toPool ? pad.poolOf(t) : address(pad);
        amount = bound(amount, 1 gwei, 1 ether);
        vm.prank(who);
        try pad.buy{value: amount}(t, 0, to, type(uint256).max) {
            ghostPoolRecipientAccepted = true;
        } catch {}
    }

    function curveSell(uint256 w, uint256 a, uint256 amount) external {
        address t = _token(w);
        if (pad.isGraduated(t)) return;
        address who = _actor(a);
        uint256 held = IERC20(t).balanceOf(who);
        uint256 sold = pad.curves(t).tokensSold;
        if (held > sold) held = sold;
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(who);
        try pad.sell(t, amount, 0, who, type(uint256).max) {} catch {}
    }

    function graduate(uint256 w, uint256 a) external {
        address t = _token(w);
        if (pad.isGraduated(t)) return;
        address who = _actor(a);
        vm.prank(who);
        pad.buy{value: 40 ether}(t, 0, who, type(uint256).max);
        ghostGraduations++;
    }

    function transferTokens(uint256 w, uint256 a, uint256 b, uint256 amount) external {
        address t = _token(w);
        address from = _actor(a);
        uint256 held = IERC20(t).balanceOf(from);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(from);
        IERC20(t).transfer(_actor(b), amount);
    }

    function distribute(uint256 w, uint256 a, uint256 amount) external {
        address t = _token(w);
        address who = _actor(a);
        amount = bound(amount, 1, 1 ether);
        if (who.balance < amount) return;
        vm.prank(who);
        try ILaunchToken(t).distribute{value: amount}() {} catch {}
    }

    function claim(uint256 w, uint256 a) external {
        vm.prank(_actor(a));
        ILaunchToken(_token(w)).claim();
    }

    function collectFees() external {
        pad.collectFees();
    }

    function collectCreatorFees(uint256 w) external {
        address t = _token(w);
        uint256 owed = pad.pendingCreatorFees(t);
        uint256 padBefore = address(pad).balance;
        try pad.collectCreatorFees(t) returns (uint256 paid) {
            if (paid != owed || padBefore - address(pad).balance != owed) ghostPullCheckFailed = true;
            ghostPluginPaid[t] += paid;
        } catch {
            ghostCollectReverts++;
            // A failed collection leaves the fees accrued
            if (pad.pendingCreatorFees(t) != owed) ghostPullCheckFailed = true;
        }
    }

    function setFlakyMode(uint8 m) external {
        flaky.setMode(MisbehavingPlugin.Mode(m % 4));
    }
}

contract MintMarkSolvencyInvariant is MintMarkBase {
    SolvencyHandler handler;
    ExactPlugin exact;
    MisbehavingPlugin flaky;
    DistributePlugin distributor;
    LyingPlugin liar;
    address[] tokenList;

    function setUp() public override {
        super.setUp();
        exact = new ExactPlugin(pad);
        flaky = new MisbehavingPlugin();
        distributor = new DistributePlugin();
        liar = new LyingPlugin();

        vm.startPrank(alice);
        tokenList.push(pad.createToken("Zero", "ZERO", "", 0, creatorWallet, "", 0, type(uint256).max));
        tokenList.push(pad.createToken("Max", "MAX", "", 1000, address(exact), "", 0, type(uint256).max));
        tokenList.push(pad.createToken("Flaky", "FLKY", "", 333, address(flaky), "", 0, type(uint256).max));
        tokenList.push(pad.createToken("Share", "SHARE", "", 50, address(distributor), "", 0, type(uint256).max));
        tokenList.push(pad.createToken("Liar", "LIAR", "", 777, address(liar), "", 0, type(uint256).max));
        vm.stopPrank();
        // One token starts graduated so post-graduation paths run from the first call
        _graduate(tokenList[1]);

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("trader1");
        actors[1] = makeAddr("trader2");
        actors[2] = makeAddr("trader3");
        handler = new SolvencyHandler(pad, flaky, tokenList, actors);
        targetContract(address(handler));
    }

    /// @notice ETH held == pendingFees + Σ pendingCreatorFees + Σ live floats, to the wei.
    function invariant_solvencyToTheWei() public view {
        _assertSolvent();
    }

    /// @notice The curves keep their shape, and a graduated curve left nothing behind.
    function invariant_curves() public view {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address t = tokenList[i];
            IMintMarkLaunchpad.Curve memory c = pad.curves(t);
            assertEq(uint256(c.virtualTokens) + uint256(c.tokensSold), VIRTUAL_TOKENS_0);
            assertLe(uint256(c.tokensSold), CURVE_SUPPLY);
            assertGe(uint256(c.virtualEth), VIRTUAL_ETH_0);
            if (c.graduated) {
                assertEq(IERC20(t).balanceOf(address(pad)), 0);
                assertEq(uint256(c.tokensSold), CURVE_SUPPLY);
                MockPair pool = MockPair(c.pool);
                assertGe(pool.balanceOf(DEAD), 1000, "LP locked at the dead address");
                // All LP but the mock's MINIMUM_LIQUIDITY (minted to its own sink) is at the dead address
                assertEq(pool.balanceOf(DEAD) + 1000, pool.totalSupply(), "no one else holds LP");
                assertEq(IERC20(t).allowance(address(pad), address(migrator)), 0, "no allowance left behind");
            } else {
                assertEq(IERC20(t).balanceOf(address(pad)), TOTAL_SUPPLY - uint256(c.tokensSold));
                // The predicted pool stays empty (usually nonexistent) until graduation seeds it
                assertEq(IERC20(t).balanceOf(c.pool), 0);
                if (c.pool.code.length != 0) assertEq(MockPair(c.pool).totalSupply(), 0);
            }
        }
    }

    /// @notice Review #1 H1: no buy ever delivered into a pool or the launchpad.
    function invariant_noForbiddenBuyRecipients() public view {
        assertFalse(handler.ghostPoolRecipientAccepted(), "a buy delivered into the pool or the launchpad");
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (!pad.isGraduated(tokenList[i])) {
                assertFalse(LaunchToken(tokenList[i]).poolUnlocked(), "a live curve's pool came unlocked");
            }
        }
    }

    /// @notice Every plugin credit is backed by ETH that actually arrived, and collections moved exactly what was owed.
    function invariant_feesBackedExactly() public view {
        assertFalse(handler.ghostPullCheckFailed(), "a collection moved other than exactly what was owed");
        assertEq(exact.received(tokenList[1]), address(exact).balance, "credits == ETH received");
        assertEq(handler.ghostPluginPaid(tokenList[1]), exact.received(tokenList[1]));
        assertEq(handler.ghostPluginPaid(tokenList[4]), address(liar).balance);
        assertEq(liar.hookCalls(), 0);
    }

    /// @notice The migrator never holds anything between calls.
    function invariant_migratorHoldsNothing() public view {
        assertEq(address(migrator).balance, 0);
        for (uint256 i = 0; i < tokenList.length; i++) {
            assertEq(IERC20(tokenList[i]).balanceOf(address(migrator)), 0);
        }
        assertEq(weth.balanceOf(address(migrator)), 0);
    }

    function afterInvariant() public view {
        // Evidence the run exercised the interesting paths (printed with -vv)
        console.log("graduations", handler.ghostGraduations());
        console.log("failed collections", handler.ghostCollectReverts());
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 2. Dividends: Σ claimable + Σ claimed ≤ Σ distributed, excluded accounts never accrue,
//    through curve trades (pulls), transfers, burns, sends to DEAD, pool moves, distributions and claims.
// ═══════════════════════════════════════════════════════════════════════════════

contract DividendHandler is Test {
    MintMarkLaunchpad public pad;
    ILaunchToken public token;
    address[] public actors;

    uint256 public ghostDistributions;
    uint256 public ghostDistributedWithoutHolders; // coverage: distributions while the stream was paused
    uint256 public ghostBurned;
    uint256 public ghostPoolMoves; // coverage: tokens crossing the pool (excluded) boundary
    uint256 public ghostEveryoneOut; // coverage: times every actor sold out (nobody eligible)

    constructor(MintMarkLaunchpad _pad, address _token, address[] memory _actors) {
        pad = _pad;
        token = ILaunchToken(_token);
        actors = _actors;
        for (uint256 i = 0; i < _actors.length; i++) {
            vm.deal(_actors[i], 1_000_000 ether);
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 a) internal view returns (address) {
        return actors[a % actors.length];
    }

    function buy(uint256 a, uint256 amount) external {
        address who = _actor(a);
        if (pad.isGraduated(address(token))) {
            // A pool buy: tokens leave the (excluded) pool for the buyer
            address pool = pad.poolOf(address(token));
            uint256 poolBal = token.balanceOf(pool);
            if (poolBal < 10) return;
            vm.prank(pool);
            token.transfer(who, bound(amount, 1, poolBal / 10));
            MockPair(pool).sync();
            ghostPoolMoves++;
        } else {
            amount = bound(amount, 1, 1 ether);
            vm.prank(who);
            try pad.buy{value: amount}(address(token), 0, who, type(uint256).max) {} catch {}
        }
    }

    function sell(uint256 a, uint256 amount) external {
        address who = _actor(a);
        uint256 held = token.balanceOf(who);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        if (pad.isGraduated(address(token))) {
            // A pool sell: tokens enter the open pool
            address pool = pad.poolOf(address(token));
            vm.prank(who);
            token.transfer(pool, amount);
            MockPair(pool).sync();
            ghostPoolMoves++;
        } else {
            vm.prank(who);
            try pad.sell(address(token), amount, 0, who, type(uint256).max) {} catch {}
        }
    }

    function graduate(uint256 a) external {
        if (pad.isGraduated(address(token))) return;
        address who = _actor(a);
        vm.prank(who);
        pad.buy{value: 40 ether}(address(token), 0, who, type(uint256).max);
    }

    function transfer(uint256 a, uint256 b, uint256 amount) external {
        address from = _actor(a);
        uint256 held = token.balanceOf(from);
        if (held == 0) return;
        amount = bound(amount, 0, held);
        vm.prank(from);
        token.transfer(_actor(b), amount);
    }

    function sendToDead(uint256 a, uint256 amount) external {
        address from = _actor(a);
        uint256 held = token.balanceOf(from);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(from);
        token.transfer(0x000000000000000000000000000000000000dEaD, amount);
    }

    function burn(uint256 a, uint256 amount) external {
        address from = _actor(a);
        uint256 held = token.balanceOf(from);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(from);
        token.burn(amount);
        ghostBurned += amount;
    }

    /// @dev Never reverts for lack of eligible supply: the stream waits.
    function distribute(uint256 a, uint256 amount) external {
        amount = bound(amount, 0, 4 ether);
        address who = _actor(a);
        if (who.balance < amount) return;
        if (token.eligibleSupply() == 0) ghostDistributedWithoutHolders++;
        vm.prank(who);
        token.distribute{value: amount}();
        ghostDistributions++;
    }

    /// @dev Rarely, every actor sells everything, so nobody is eligible and a running stream pauses until someone buys.
    function everyoneSells(uint256 seed) external {
        if (uint256(keccak256(abi.encode(seed))) % 8 != 0) return;
        bool pool = pad.isGraduated(address(token));
        for (uint256 i = 0; i < actors.length; i++) {
            address who = actors[i];
            uint256 held = token.balanceOf(who);
            if (held == 0) continue;
            vm.prank(who);
            if (pool) {
                token.transfer(pad.poolOf(address(token)), held);
            } else {
                try pad.sell(address(token), held, 0, who, block.timestamp) {} catch {}
            }
        }
        if (token.eligibleSupply() == 0) ghostEveryoneOut++;
    }

    /// @dev Time passes, so the stream pays out (or, with nobody holding, stays paused).
    function warp(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 2 days));
    }

    /// @dev Creator fees collected to the DistributePlugin, which distributes them through the token.
    function collect() external {
        try pad.collectCreatorFees(address(token)) returns (uint256 paid) {
            if (paid > 0) ghostDistributions++;
        } catch {}
    }

    function claim(uint256 a) external {
        vm.prank(_actor(a));
        token.claim();
    }

    function claimFor(uint256 caller, uint256 a) external {
        vm.prank(_actor(caller));
        token.claimFor(_actor(a));
    }
}

contract LaunchTokenDividendInvariant is MintMarkBase {
    DividendHandler handler;
    ILaunchToken token;
    address[] actors;

    function setUp() public override {
        super.setUp();
        DistributePlugin plugin = new DistributePlugin();
        vm.prank(alice);
        token = ILaunchToken(pad.createToken("Dividend", "DIV", "", 500, address(plugin), "", 0, type(uint256).max));
        actors.push(makeAddr("holder1"));
        actors.push(makeAddr("holder2"));
        actors.push(makeAddr("holder3"));
        actors.push(makeAddr("holder4"));
        handler = new DividendHandler(pad, address(token), actors);
        targetContract(address(handler));
    }

    function _sums() internal view returns (uint256 claimable, uint256 claimed, uint256 balances) {
        for (uint256 i = 0; i < actors.length; i++) {
            claimable += token.claimable(actors[i]);
            claimed += token.claimed(actors[i]);
            balances += token.balanceOf(actors[i]);
        }
    }

    /// @notice Σ claimable + Σ claimed ≤ Σ distributed, and everything not yet credited is either still streaming
    ///         (undistributed) or rounding dust.
    function invariant_neverOverCredits() public view {
        (uint256 claimable, uint256 claimed,) = _sums();
        uint256 distributed = token.totalDistributed();
        assertLe(claimable + claimed, distributed, "credited more than was distributed");
        // Floors lose < 1 wei per distribution and < 1 wei per account
        assertLe(
            distributed - (claimable + claimed) - token.undistributed(),
            handler.ghostDistributions() + actors.length + 1,
            "dust bound"
        );
    }

    /// @notice The tracked eligible supply is the formula it replaced (total supply minus the launchpad's, the
    ///         pool's and 0x…dEaD's balances), through buys, sells, transfers, pulls, burns, graduation and pool
    ///         moves; and a running stream never ends more than DRIP_PERIOD after its last accrual.
    function invariant_eligibleSupplyIsTheFormula() public view {
        uint256 formula = token.totalSupply() - token.balanceOf(address(pad)) - token.balanceOf(pad.poolOf(address(token)))
            - token.balanceOf(DEAD);
        assertEq(token.eligibleSupply(), formula < token.MIN_ELIGIBLE_SUPPLY() ? 0 : formula);
        // streamEnd() reports the end as of now, so while paused it includes the paused time since lastAccrual; the
        // stored end the window bound is about is that minus the paused time.
        uint256 last = token.lastAccrual();
        uint256 end = token.streamEnd();
        if (last < end) {
            if (token.eligibleSupply() == 0) end -= vm.getBlockTimestamp() - last;
            assertLe(end - last, token.DRIP_PERIOD());
        }
    }

    /// @notice The token holds exactly what has been distributed and not yet claimed, which covers every claim.
    function invariant_ethBacksEveryClaim() public view {
        (uint256 claimable, uint256 claimed,) = _sums();
        uint256 held = address(token).balance;
        assertEq(held, token.totalDistributed() - claimed);
        assertGe(held, claimable);
    }

    /// @notice Excluded accounts never accrue, and eligible supply is exactly the actors' balances.
    function invariant_exclusions() public view {
        address pool = pad.poolOf(address(token));
        address[4] memory excluded = [address(pad), pool, DEAD, address(0)];
        for (uint256 i = 0; i < excluded.length; i++) {
            assertTrue(token.isExcluded(excluded[i]));
            assertEq(token.claimable(excluded[i]), 0);
            assertEq(token.claimed(excluded[i]), 0);
        }
        (,, uint256 balances) = _sums();
        // eligible supply == the non-excluded holders' balances (reported as 0 while under one whole token)
        assertEq(token.eligibleSupply(), balances < token.MIN_ELIGIBLE_SUPPLY() ? 0 : balances);
        assertEq(
            token.totalSupply(),
            balances + token.balanceOf(address(pad)) + token.balanceOf(pool) + token.balanceOf(DEAD),
            "every token is somewhere"
        );
        assertEq(token.totalSupply(), TOTAL_SUPPLY - handler.ghostBurned());
    }

    function afterInvariant() public view {
        console.log("distributions", handler.ghostDistributions());
        console.log("distributed with nobody eligible (stream paused)", handler.ghostDistributedWithoutHolders());
        console.log("pool boundary moves", handler.ghostPoolMoves());
        console.log("everyone sold out", handler.ghostEveryoneOut());
        console.log("graduated", pad.isGraduated(address(token)));
    }
}
