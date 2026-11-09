// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
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

/// @notice The whole launch lifecycle against the REAL PancakeSwap V2 factory on a Linea mainnet fork:
///         the migrator's constructor probe (pair-code-hash proof against allPairs(0)), a launch, curve trades,
///         and the sell-out buy graduating into a real Pancake pair with the LP burned.
///         Runs only with LINEA_FORK_RPC_URL set (e.g. https://linea-rpc.publicnode.com); skipped otherwise.
contract LineaForkTest is Test {
    // PancakeSwap V2 on Linea, verified on-chain 2026-10-06 (docs/PLUGIN-MARKETPLACE-SPEC.md §1); the init-code
    // hash is the one Metapad fork-verified for this router (metapad dexes.ts "linea").
    address constant PANCAKE_V2_ROUTER = 0x8cFe327CEc66d1C090Dd72bd0FF11d690C33a2Eb;
    bytes32 constant PANCAKE_PAIR_CODE_HASH = 0x57224589c67f3f30a6b0d7a1b54cf3153ab84563bc609ef41dfb34f8b2974d2d;
    address constant LINEA_WETH = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;

    V2Migrator migrator;
    MintMarkLaunchpad pad;
    address feeTo = makeAddr("feeTo");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("LINEA_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        migrator = new V2Migrator(PANCAKE_V2_ROUTER, PANCAKE_PAIR_CODE_HASH);
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
        assertEq(migrator.weth(), LINEA_WETH, "the router's WETH is Linea's canonical WETH");
        // A wrong hash fails the constructor probe
        vm.expectRevert(V2Migrator.InvalidDex.selector);
        new V2Migrator(PANCAKE_V2_ROUTER, bytes32(uint256(1)));
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

        // Nobody can deposit into the predicted Pancake pair early
        address pool = pad.poolOf(token);
        assertEq(pool, migrator.poolFor(token));
        vm.prank(bob);
        vm.expectRevert(ILaunchToken.PoolLocked.selector);
        IERC20(token).transfer(pool, 1);

        // Sell out: graduation seeds the real Pancake pair and burns the LP
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, block.timestamp);
        assertTrue(pad.isGraduated(token));
        assertEq(ILaunchToken(token).vault(), address(0), "the real DEX migration succeeded");
        IV2PairView pair = IV2PairView(pool);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 reserveToken, uint256 reserveWeth) = pair.token0() == token ? (r0, r1) : (r1, r0);
        assertEq(reserveToken, pad.POOL_SUPPLY());
        assertEq(reserveWeth, uint256(pad.curves(token).virtualEth) - pad.VIRTUAL_ETH_0());
        // All LP but Pancake's MINIMUM_LIQUIDITY (locked at address zero by the pair itself) is at the dead address
        assertEq(pair.balanceOf(0x000000000000000000000000000000000000dEaD) + 1000, pair.totalSupply());
        assertEq(IERC20(token).balanceOf(address(pad)), 0);

        // The platform's fees collect
        uint256 owed = pad.pendingFees();
        pad.collectFees();
        assertEq(feeTo.balance, owed);
    }
}
