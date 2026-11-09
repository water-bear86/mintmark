// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMigrator.sol";

interface IUniswapV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address a, address b) external view returns (address);
    function createPair(address a, address b) external returns (address);
    function allPairs(uint256 i) external view returns (address);
    function allPairsLength() external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function mint(address to) external returns (uint256 liquidity);
}

interface IWETH {
    function deposit() external payable;
}

/// @title V2Migrator (MintMark)
/// @notice Seeds a token/wrapped-native pool on a configured Uniswap V2-compatible DEX with a graduated
///         curve's liquidity, and burns the LP tokens so the liquidity is locked forever. A native-value-only port
///         of Metapad's fork-tested UniswapV2Migrator. Stateless and holds no funds between calls.
contract V2Migrator is IMigrator {
    using SafeERC20 for IERC20;

    address public constant LP_RECIPIENT = 0x000000000000000000000000000000000000dEaD;

    address public immutable router;
    address public immutable dexFactory;
    address public immutable weth;
    /// @notice keccak256 of the DEX's pair creation code, used to know a pair's address before it exists.
    bytes32 public immutable pairCodeHash;

    event Migrated(address indexed token, address indexed pool, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity);

    error InvalidDex();
    error PoolMismatch();

    /// @dev Proves `pairCodeHash` against the DEX's first existing pair, so a wrong hash can't be configured.
    constructor(address router_, bytes32 pairCodeHash_) {
        router = router_;
        dexFactory = IUniswapV2Router(router_).factory();
        weth = IUniswapV2Router(router_).WETH();
        pairCodeHash = pairCodeHash_;
        if (dexFactory == address(0) || weth == address(0)) revert InvalidDex();

        IUniswapV2Factory f = IUniswapV2Factory(dexFactory);
        if (f.allPairsLength() == 0) revert InvalidDex();
        IUniswapV2Pair probe = IUniswapV2Pair(f.allPairs(0));
        if (_pairFor(probe.token0(), probe.token1()) != address(probe)) revert InvalidDex();
    }

    /// @inheritdoc IMigrator
    function poolFor(address token) public view returns (address) {
        (address t0, address t1) = token < weth ? (token, weth) : (weth, token);
        return _pairFor(t0, t1);
    }

    /// @inheritdoc IMigrator
    /// @dev The pool can hold no tokens before this call (LaunchToken blocks it), so it has no LP holders and the
    ///      price is set by this deposit. WETH donated to the pool beforehand just joins the locked liquidity.
    function migrate(address token, uint256 tokenAmount) external payable returns (address pool, uint256 liquidity) {
        pool = poolFor(token);
        IUniswapV2Factory f = IUniswapV2Factory(dexFactory);
        if (f.getPair(token, weth) == address(0) && f.createPair(token, weth) != pool) revert PoolMismatch();

        IERC20(token).safeTransferFrom(msg.sender, pool, tokenAmount);
        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).safeTransfer(pool, msg.value);
        liquidity = IUniswapV2Pair(pool).mint(LP_RECIPIENT);
        emit Migrated(token, pool, tokenAmount, msg.value, liquidity);
    }

    function _pairFor(address token0, address token1) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", dexFactory, salt, pairCodeHash)))));
    }
}
