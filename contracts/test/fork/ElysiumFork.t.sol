// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ElysiumPreflight} from "../../script/ElysiumPreflight.sol";
import "../../launchpad/MintMarkLaunchpad.sol";
import "../../launchpad/LaunchToken.sol";
import "../../launchpad/V2Migrator.sol";
import "../../interfaces/IMintMarkLaunchpad.sol";
import "../../interfaces/ILaunchToken.sol";

interface IV2PairView {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IElysiumV2TradingRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external;
}

/// @notice Opt-in Elysium fork lifecycle. No broadcasts; all changes exist only in the local fork.
contract ElysiumForkTest is Test {
    address wrappedHype;
    address router;
    bytes32 pairHash;
    V2Migrator migrator;
    MintMarkLaunchpad pad;
    address feeTo = makeAddr("feeTo");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("ELYSIUM_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("ELYSIUM_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        router = vm.envAddress("V2_ROUTER");
        pairHash = vm.envBytes32("V2_PAIR_CODE_HASH");
        wrappedHype = vm.envAddress("ELYSIUM_WHYPE");
        ElysiumPreflight.validate(vm.envUint("ELYSIUM_CHAIN_ID"), router, wrappedHype, pairHash);
        migrator = new V2Migrator(router, pairHash);
        pad = new MintMarkLaunchpad(address(migrator), feeTo, feeTo, 0.001 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    modifier onFork() {
        if (address(pad) == address(0)) {
            vm.skip(true);
        }
        _;
    }

    function test_migratorProbe_provesThePairCodeHashOnChain() public onFork {
        assertEq(migrator.weth(), wrappedHype, "the router's WETH is Elysium's configured WHYPE");
        // A wrong hash fails the constructor probe
        vm.expectRevert(V2Migrator.InvalidDex.selector);
        new V2Migrator(router, bytes32(uint256(1)));
    }

    function test_fullLifecycleOnTheRealDex() public onFork {
        // Launch with a first buy
        vm.prank(alice);
        address token = pad.createToken{value: 0.101 ether}("Fork", "FORK", "ipfs://fork", 500, alice, "", 0, 0.001 ether);
        uint256 firstBuyFee = (uint256(0.1 ether) * 50 + 9999) / 10000; // ceil(0.5%)
        assertEq(pad.pendingFees(), 0.001 ether + firstBuyFee);
        assertGt(IERC20(token).balanceOf(alice), 0);

        // Trade both ways
        vm.prank(bob);
        (uint256 got,) = pad.buy{value: 1 ether}(token, 0, bob, block.timestamp);
        vm.prank(bob);
        pad.sell(token, got / 2, 0, bob, block.timestamp);

        // Nobody can deposit into the predicted V2 pair early
        address pool = pad.poolOf(token);
        assertEq(pool, migrator.poolFor(token));
        vm.prank(bob);
        vm.expectRevert(ILaunchToken.PoolLocked.selector);
        IERC20(token).transfer(pool, 1);

        // Sell out: graduation seeds the real V2 pair and burns the LP
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, block.timestamp);
        assertTrue(pad.isGraduated(token));
        assertEq(ILaunchToken(token).vault(), address(0), "the real DEX migration succeeded");
        IV2PairView pair = IV2PairView(pool);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 reserveToken, uint256 reserveWeth) = pair.token0() == token ? (r0, r1) : (r1, r0);
        assertEq(reserveToken, pad.POOL_SUPPLY());
        assertEq(reserveWeth, uint256(pad.curves(token).virtualEth) - pad.VIRTUAL_ETH_0());
        assertGe(reserveWeth, 30 ether, "30 HYPE baseline plus trade-rounding dust");
        // All LP but V2's MINIMUM_LIQUIDITY (locked at address zero by the pair itself) is at the dead address
        assertEq(pair.balanceOf(0x000000000000000000000000000000000000dEaD) + 1000, pair.totalSupply());
        assertEq(IERC20(token).balanceOf(address(pad)), 0);

        // The platform's fees collect
        uint256 owed = pad.pendingFees();
        pad.collectFees();
        assertEq(feeTo.balance, owed);
    }

    function _graduateForRouterTests() internal returns (address token) {
        vm.prank(alice);
        token = pad.createToken{value: 0.001 ether}("Graduated Fork", "GFORK", "ipfs://fork", 0, alice, "", 0, 0.001 ether);
        vm.prank(alice);
        pad.buy{value: 40 ether}(token, 0, alice, block.timestamp);
        assertTrue(pad.isGraduated(token));
        assertEq(ILaunchToken(token).vault(), address(0), "real V2 migration must succeed");
        assertEq(IERC20(wrappedHype).balanceOf(pad.poolOf(token)), 30 ether, "fresh net liquidity");
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2); path[0] = a; path[1] = b;
    }

    function test_graduatedRouter_nativeBuyExactApprovalAndNativeSell() public onFork {
        address token = _graduateForRouterTests();
        IElysiumV2TradingRouter dex = IElysiumV2TradingRouter(router);
        address[] memory buyPath = _path(wrappedHype, token);
        uint256 hypeIn = 0.1 ether;
        uint256 expectedTokens = dex.getAmountsOut(hypeIn, buyPath)[1];
        uint256 nativeBefore = bob.balance;
        vm.prank(bob);
        dex.swapExactETHForTokensSupportingFeeOnTransferTokens{value: hypeIn}(expectedTokens, buyPath, bob, block.timestamp + 120);
        assertEq(IERC20(token).balanceOf(bob), expectedTokens);
        assertEq(bob.balance, nativeBefore - hypeIn, "buy consumes native HYPE");
        assertEq(IERC20(wrappedHype).balanceOf(bob), 0, "no manual wrap required");
        assertEq(IERC20(token).allowance(bob, router), 0);

        address[] memory sellPath = _path(token, wrappedHype);
        uint256 expectedHype = dex.getAmountsOut(expectedTokens, sellPath)[1];
        // Unlike curve sells, the DEX router needs an explicit token allowance.
        vm.prank(bob);
        vm.expectRevert();
        dex.swapExactTokensForETHSupportingFeeOnTransferTokens(expectedTokens, expectedHype, sellPath, bob, block.timestamp + 120);
        vm.prank(bob);
        assertTrue(IERC20(token).approve(router, expectedTokens));
        assertEq(IERC20(token).allowance(bob, router), expectedTokens, "exact approval only");
        uint256 beforeSell = bob.balance;
        vm.prank(bob);
        dex.swapExactTokensForETHSupportingFeeOnTransferTokens(expectedTokens, expectedHype, sellPath, bob, block.timestamp + 120);
        assertEq(bob.balance, beforeSell + expectedHype, "sell unwraps to native HYPE");
        assertEq(IERC20(token).balanceOf(bob), 0);
        assertEq(IERC20(wrappedHype).balanceOf(bob), 0);
        assertEq(IERC20(token).allowance(bob, router), 0, "exact allowance consumed");
        assertLt(expectedHype, hypeIn, "round trip pays pool fees");
    }

    function test_graduatedRouter_slippageRevertsAtomically() public onFork {
        address token = _graduateForRouterTests();
        IElysiumV2TradingRouter dex = IElysiumV2TradingRouter(router);
        address[] memory buyPath = _path(wrappedHype, token);
        uint256 hypeIn = 0.1 ether;
        uint256 quoted = dex.getAmountsOut(hypeIn, buyPath)[1];
        uint256 nativeBefore = bob.balance;
        vm.prank(bob);
        vm.expectRevert(bytes("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"));
        dex.swapExactETHForTokensSupportingFeeOnTransferTokens{value: hypeIn}(quoted + 1, buyPath, bob, block.timestamp + 120);
        assertEq(bob.balance, nativeBefore);
        assertEq(IERC20(token).balanceOf(bob), 0);
        vm.prank(bob);
        dex.swapExactETHForTokensSupportingFeeOnTransferTokens{value: hypeIn}(quoted, buyPath, bob, block.timestamp + 120);
        vm.prank(bob);
        IERC20(token).approve(router, quoted);
        address[] memory sellPath = _path(token, wrappedHype);
        uint256 expectedHype = dex.getAmountsOut(quoted, sellPath)[1];
        vm.prank(bob);
        vm.expectRevert(bytes("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"));
        dex.swapExactTokensForETHSupportingFeeOnTransferTokens(quoted, expectedHype + 1, sellPath, bob, block.timestamp + 120);
        assertEq(IERC20(token).balanceOf(bob), quoted);
        assertEq(IERC20(token).allowance(bob, router), quoted);
        assertEq(bob.balance, nativeBefore - hypeIn);
    }

    function test_graduatedRouter_expiredBuyAndSellRevert() public onFork {
        address token = _graduateForRouterTests();
        IElysiumV2TradingRouter dex = IElysiumV2TradingRouter(router);
        vm.prank(bob);
        vm.expectRevert(bytes("UniswapV2Router: EXPIRED"));
        dex.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(0, _path(wrappedHype, token), bob, block.timestamp - 1);
        // Alice holds curve-bought tokens after graduation; expiry applies even with valid approval.
        uint256 tokensIn = IERC20(token).balanceOf(alice) / 100;
        vm.prank(alice);
        IERC20(token).approve(router, tokensIn);
        vm.prank(alice);
        vm.expectRevert(bytes("UniswapV2Router: EXPIRED"));
        dex.swapExactTokensForETHSupportingFeeOnTransferTokens(tokensIn, 0, _path(token, wrappedHype), alice, block.timestamp - 1);
        assertEq(IERC20(token).allowance(alice, router), tokensIn);
    }
}
