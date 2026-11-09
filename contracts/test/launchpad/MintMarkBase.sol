// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../launchpad/MintMarkLaunchpad.sol";
import "../../launchpad/LaunchToken.sol";
import "../../launchpad/V2Migrator.sol";
import "../../launchpad/GraduationVault.sol";
import "../../interfaces/IMintMarkFeePlugin.sol";
import "../../interfaces/IMintMarkLaunchpad.sol";
import "../../interfaces/ILaunchToken.sol";

// ─── Minimal V2 DEX stand-ins (same pair addressing and first-mint maths as Uniswap/Pancake V2) ────────

contract MockWETH is ERC20("Wrapped Ether", "WETH") {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockPair is ERC20("V2 Pair", "V2-LP") {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    address public factory;
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor() {
        factory = msg.sender;
    }

    function initialize(address t0, address t1) external {
        require(msg.sender == factory, "FORBIDDEN");
        (token0, token1) = (t0, t1);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function mint(address to) external returns (uint256 liquidity) {
        require(!MockV2Factory(factory).mintBroken(), "BROKEN");
        if (MockV2Factory(factory).mintBurnsGas()) {
            while (true) {}
        }
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - reserve0;
        uint256 a1 = b1 - reserve1;
        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(a0 * a1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead0000), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(a0 * supply / reserve0, a1 * supply / reserve1);
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _sync(b0, b1);
    }

    function sync() external {
        _sync(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function _sync(uint256 b0, uint256 b1) internal {
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "OVERFLOW");
        (reserve0, reserve1) = (uint112(b0), uint112(b1));
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    bool public mintBroken;
    bool public mintBurnsGas;

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function setMintBroken(bool v) external {
        mintBroken = v;
    }

    function setMintBurnsGas(bool v) external {
        mintBurnsGas = v;
    }

    function createPair(address a, address b) external returns (address pair) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        require(getPair[t0][t1] == address(0), "PAIR_EXISTS");
        pair = address(new MockPair{salt: keccak256(abi.encodePacked(t0, t1))}());
        MockPair(pair).initialize(t0, t1);
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
        allPairs.push(pair);
    }
}

contract MockRouter {
    address public factory;
    address public WETH;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH = weth_;
    }
}

contract SeedToken is ERC20("Seed", "SEED") {
    constructor() {
        _mint(msg.sender, 1e24);
    }
}

// ─── Mock fee plugins (test-only; the real plugins live in contracts/plugins/launch/) ─────────────────

/// @dev A well-behaved IMintMarkFeePlugin: accepts onLaunch only from the launchpad, records what it saw at that
///      moment, and credits exactly the ETH each onFees call carries.
contract ExactPlugin is ERC165, IMintMarkFeePlugin {
    IMintMarkLaunchpad public immutable pad;

    mapping(address => uint256) public received;
    uint256 public launches;
    uint256 public feeCalls;
    address public lastToken;
    address public lastCreator;
    bytes public lastData;
    // Observed inside onLaunch
    bool public curveRegisteredAtLaunch;
    uint256 public soldAtLaunch;
    uint256 public creatorBalanceAtLaunch;

    constructor(IMintMarkLaunchpad pad_) {
        pad = pad_;
    }

    function supportsInterface(bytes4 id) public view override(ERC165, IERC165) returns (bool) {
        return id == type(IMintMarkFeePlugin).interfaceId || super.supportsInterface(id);
    }

    function onLaunch(address token, address creator, bytes calldata data) external {
        require(msg.sender == address(pad), "only launchpad");
        launches++;
        lastToken = token;
        lastCreator = creator;
        lastData = data;
        // Every per-token view is a plain view, callable while createToken is still running
        curveRegisteredAtLaunch = pad.pluginOf(token) == address(this) && pad.creatorOf(token) == creator
            && pad.poolOf(token) != address(0) && !pad.isGraduated(token)
            && pad.virtualEthOf(token) == pad.VIRTUAL_ETH_0() && pad.creatorFeeBpsOf(token) == pad.curves(token).creatorFeeBps
            && pad.curves(token).pluginHooks;
        soldAtLaunch = pad.curves(token).tokensSold;
        creatorBalanceAtLaunch = IERC20(token).balanceOf(creator);
    }

    function onFees(address token, uint256 amount) external payable {
        feeCalls++;
        require(msg.value == amount, "value");
        received[token] += amount;
    }
}

/// @dev A plugin that declares the interface and then misbehaves in a chosen way.
contract MisbehavingPlugin is ERC165, IMintMarkFeePlugin {
    enum Mode {
        Exact,
        Revert,
        SendBack,
        Forward
    }

    Mode public mode;
    bool public revertOnLaunch;
    address public constant THIRD_PARTY = address(0x7777);

    function supportsInterface(bytes4 id) public view override(ERC165, IERC165) returns (bool) {
        return id == type(IMintMarkFeePlugin).interfaceId || super.supportsInterface(id);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setRevertOnLaunch(bool v) external {
        revertOnLaunch = v;
    }

    function onLaunch(address, address, bytes calldata) external view {
        require(!revertOnLaunch, "onLaunch refuses");
    }

    function onFees(address, uint256) external payable {
        Mode m = mode;
        if (m == Mode.Exact) {
            // keeps the ETH
        } else if (m == Mode.Revert) {
            revert("plugin broken");
        } else if (m == Mode.SendBack) {
            // the launchpad's receive() reverts, so this reverts the collection
            payable(msg.sender).transfer(1);
        } else {
            (bool ok,) = THIRD_PARTY.call{value: msg.value}("");
            require(ok, "forward");
        }
    }
}

/// @dev Answers true to every interface id, including 0xffffffff, which ERC-165 requires to be false. The
///      launchpad must therefore treat it as a plain address: no hooks, a plain send.
contract LyingPlugin {
    uint256 public hookCalls;

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function onLaunch(address, address, bytes calldata) external {
        hookCalls++;
    }

    function onFees(address, uint256) external payable {
        hookCalls++;
    }

    receive() external payable {}
}

/// @dev A plugin whose ERC-165 answer can change after launch (an upgradeable proxy, say). Credits per token only
///      through onFees, like the real plugins; anything that arrives otherwise is uncredited.
contract FlippablePlugin is IMintMarkFeePlugin {
    bool public declares;
    mapping(address => bool) public configured;
    mapping(address => uint256) public credited;
    uint256 public launches;
    uint256 public feeCalls;

    constructor(bool declares_) {
        declares = declares_;
    }

    function setDeclares(bool v) external {
        declares = v;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        if (id == 0xffffffff) return false;
        if (id == type(IERC165).interfaceId) return true;
        return declares && id == type(IMintMarkFeePlugin).interfaceId;
    }

    function onLaunch(address token, address, bytes calldata) external {
        launches++;
        configured[token] = true;
    }

    function onFees(address token, uint256 amount) external payable {
        require(configured[token], "not configured");
        require(msg.value == amount, "value");
        feeCalls++;
        credited[token] += amount;
    }

    receive() external payable {}
}

/// @dev An onLaunch that costs about as much as the heaviest listed configuration (a full Combo, ~1.3M gas): it
///      writes `slots` fresh storage slots.
contract HeavyLaunchPlugin is ERC165, IMintMarkFeePlugin {
    uint256 public immutable slots;
    mapping(uint256 => uint256) public store;
    uint256 public gasAtLaunch;

    constructor(uint256 slots_) {
        slots = slots_;
    }

    function supportsInterface(bytes4 id) public view override(ERC165, IERC165) returns (bool) {
        return id == type(IMintMarkFeePlugin).interfaceId || super.supportsInterface(id);
    }

    function onLaunch(address, address, bytes calldata) external {
        gasAtLaunch = gasleft();
        for (uint256 i = 0; i < slots; i++) {
            store[i] = i + 1;
        }
    }

    function onFees(address, uint256) external payable {}
}

/// @dev supportsInterface burns every unit of gas it is given. ERC165Checker caps the probe at 30k gas, so the
///      launchpad treats it as a plain address rather than getting stuck.
contract GasGuzzlerPlugin {
    uint256 public hookCalls;

    function supportsInterface(bytes4) external view returns (bool) {
        uint256 x;
        while (gasleft() > 0) {
            x++;
        }
        return x > 0;
    }

    function onLaunch(address, address, bytes calldata) external {
        hookCalls++;
    }

    function onFees(address, uint256) external payable {
        hookCalls++;
    }

    receive() external payable {}
}

/// @dev Has the hook functions but does not declare them through ERC-165 (no supportsInterface at all).
contract HooklessRecorder {
    uint256 public hookCalls;

    function onLaunch(address, address, bytes calldata) external {
        hookCalls++;
    }

    function onFees(address, uint256) external payable {
        hookCalls++;
    }

    receive() external payable {}
}

/// @dev Tries to re-enter the launchpad from inside onLaunch and onFees, records the revert selector of each
///      attempt, and otherwise behaves (credits the exact value).
contract ReentrantPlugin is ERC165, IMintMarkFeePlugin {
    IMintMarkLaunchpad public immutable pad;
    bytes4[] public errors;
    bool public anyReentrySucceeded;

    constructor(IMintMarkLaunchpad pad_) payable {
        pad = pad_;
    }

    function supportsInterface(bytes4 id) public view override(ERC165, IERC165) returns (bool) {
        return id == type(IMintMarkFeePlugin).interfaceId || super.supportsInterface(id);
    }

    function errorsLength() external view returns (uint256) {
        return errors.length;
    }

    function _attempt(address token) internal {
        try pad.buy{value: 1 ether}(token, 0, address(this), type(uint256).max) {
            anyReentrySucceeded = true;
        } catch (bytes memory e) {
            errors.push(bytes4(e));
        }
        try pad.sell(token, 1, 0, address(this), type(uint256).max) {
            anyReentrySucceeded = true;
        } catch (bytes memory e) {
            errors.push(bytes4(e));
        }
        try pad.collectCreatorFees(token) {
            anyReentrySucceeded = true;
        } catch (bytes memory e) {
            errors.push(bytes4(e));
        }
        try pad.collectFees() {
            anyReentrySucceeded = true;
        } catch (bytes memory e) {
            errors.push(bytes4(e));
        }
        try pad.createToken{value: 1 ether}("Re", "RE", "", 0, address(this), "", 0, type(uint256).max) {
            anyReentrySucceeded = true;
        } catch (bytes memory e) {
            errors.push(bytes4(e));
        }
    }

    function onLaunch(address token, address, bytes calldata) external {
        _attempt(token);
    }

    function onFees(address token, uint256 amount) external payable {
        _attempt(token);
        require(msg.value == amount, "value");
    }

    receive() external payable {}
}

/// @dev A minimal "distribute to holders" plugin: forwards the exact value through the token's dividends.
contract DistributePlugin is ERC165, IMintMarkFeePlugin {
    function supportsInterface(bytes4 id) public view override(ERC165, IERC165) returns (bool) {
        return id == type(IMintMarkFeePlugin).interfaceId || super.supportsInterface(id);
    }

    function onLaunch(address, address, bytes calldata) external {}

    function onFees(address token, uint256 amount) external payable {
        require(msg.value == amount, "value");
        ILaunchToken(token).distribute{value: amount}();
    }
}

// ─── Shared fixture ───────────────────────────────────────────────────────────

abstract contract MintMarkBase is Test {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant CURVE_SUPPLY = 800_000_000e18;
    uint256 internal constant POOL_SUPPLY = 200_000_000e18;
    uint256 internal constant VIRTUAL_TOKENS_0 = 1_066_666_667e18;
    uint256 internal constant VIRTUAL_ETH_0 = 10_000_000_012_500_000_000;
    uint256 internal constant FEE_BPS = 50;
    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockWETH internal weth;
    MockV2Factory internal dexFactory;
    MockRouter internal dexRouter;
    V2Migrator internal migrator;
    MintMarkLaunchpad internal pad;

    address internal feeTo = makeAddr("feeTo");
    address internal setter = makeAddr("setter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal mallory = makeAddr("mallory");
    address internal creatorWallet = makeAddr("creatorWallet");

    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 virtualEth,
        uint256 virtualTokens
    );

    function setUp() public virtual {
        (pad, migrator) = _deploySuite(0);
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(mallory);
    }

    /// @dev Mock DEX (with one seed pair so the migrator's constructor probe passes), migrator, launchpad.
    function _deploySuite(uint256 launchFee) internal returns (MintMarkLaunchpad p, V2Migrator m) {
        weth = new MockWETH();
        dexFactory = new MockV2Factory();
        dexRouter = new MockRouter(address(dexFactory), address(weth));
        SeedToken seedA = new SeedToken();
        SeedToken seedB = new SeedToken();
        dexFactory.createPair(address(seedA), address(seedB));
        m = new V2Migrator(address(dexRouter), keccak256(type(MockPair).creationCode));
        p = new MintMarkLaunchpad(address(m), feeTo, setter, launchFee);
    }

    function _fund(address who) internal {
        vm.deal(who, 1_000_000 ether);
    }

    /// @dev alice launches; fees go to `plugin`.
    function _create(uint16 creatorFeeBps, address plugin) internal returns (address token) {
        vm.prank(alice);
        token = pad.createToken("Vector", "VEC", "", creatorFeeBps, plugin, "", 0, type(uint256).max);
    }

    /// @dev alice launches with no creator fee, paying the creator wallet.
    function _create() internal returns (address token) {
        return _create(0, creatorWallet);
    }

    /// @dev bob buys out the curve (graduating it). 30 native coins net baseline; 40 covers the maximum creator fee.
    function _graduate(address token) internal {
        vm.prank(bob);
        pad.buy{value: 40 ether}(token, 0, bob, type(uint256).max);
        assertTrue(pad.isGraduated(token), "graduated");
    }

    function _float(address token) internal view returns (uint256) {
        IMintMarkLaunchpad.Curve memory c = pad.curves(token);
        return c.graduated ? 0 : uint256(c.virtualEth) - VIRTUAL_ETH_0;
    }

    /// @dev What the launchpad owes: platform fees, every token's creator fees, every live curve's float.
    function _owed() internal view returns (uint256 owed) {
        owed = pad.pendingFees();
        uint256 n = pad.tokensLength();
        for (uint256 i = 0; i < n; i++) {
            address t = pad.tokenAt(i);
            owed += pad.pendingCreatorFees(t) + _float(t);
        }
    }

    /// @dev ETH held == pendingFees + Σ pendingCreatorFees + Σ live floats, to the wei.
    function _assertSolvent() internal view {
        assertEq(address(pad).balance, _owed(), "ETH held == fees + creator fees + curve floats");
    }

    function _divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _poolOf(address token) internal view returns (MockPair) {
        return MockPair(pad.poolOf(token));
    }
}
