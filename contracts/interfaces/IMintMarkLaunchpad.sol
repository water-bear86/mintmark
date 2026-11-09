// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./IMintMarkLaunchpadLite.sol";

/// @notice ABI of the MintMark launchpad (docs/PLUGIN-MARKETPLACE-SPEC.md). An ETH-quoted port of the Architex
///         launchpad v1.3 (its V13-SPEC rules hold where this spec does not change them), graduating into a
///         V2 DEX pool through a migrator instead of a launch pair. Plugins rely only on IMintMarkLaunchpadLite.
interface IMintMarkLaunchpad is IMintMarkLaunchpadLite {
    struct Curve {
        address token;
        address creator;
        address pool; // the DEX pool the token graduates into (predicted at launch)
        uint128 virtualEth; // wei
        uint128 virtualTokens; // 18 decimals
        uint128 tokensSold; // 18 decimals, at most CURVE_SUPPLY
        uint64 createdAt;
        bool graduated;
        uint16 creatorFeeBps; // 0..MAX_CREATOR_FEE_BPS, on every buy and sell, locked at launch
        // Whether the plugin declared IMintMarkFeePlugin (ERC-165) at launch. Decided once: if true, onLaunch ran and
        // every collection calls onFees carrying the exact amount as msg.value; if false, collections are plain sends.
        bool pluginHooks;
        address plugin; // where creator fees are collected to, locked at launch
        string metadataURI;
    }

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed plugin,
        address pool,
        uint16 creatorFeeBps,
        string name,
        string symbol,
        string metadataURI
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 ethAmount, // gross ETH paid by a buyer, or gross ETH leaving the curve on a sell
        uint256 tokenAmount,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 virtualEth,
        uint256 virtualTokens
    );
    event Graduated(address indexed token, address indexed pool, uint256 ethSeeded, uint256 tokensSeeded, uint256 liquidityLocked);
    /// @notice Seeding the DEX pool failed; the liquidity waits in an ownerless vault anyone can retry from.
    event MigrationFailed(address indexed token, address indexed vault);
    event CreatorFeesCollected(address indexed token, address indexed plugin, uint256 amount);
    event FeeToUpdated(address indexed feeTo);
    event FeeToSetterUpdated(address indexed feeToSetter);
    event LaunchFeeUpdated(uint256 launchFee);
    event FeesCollected(address indexed feeTo, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error Forbidden();
    error UnknownToken();
    error CurveGraduated();
    error NotGraduated();
    error SlippageExceeded();
    /// @notice A curve buy or sell mined after its deadline (block.timestamp > deadline).
    error Expired();
    /// @notice A sell (or its quote) for more tokens than the curve has sold.
    error ExceedsSold();
    error InvalidName();
    error InvalidSymbol();
    error InvalidMetadata();
    error LaunchFeeTooHigh();
    /// @notice The launch fee is above the most the creator agreed to pay (it was raised after they signed).
    error LaunchFeeAboveMax();
    /// @notice msg.value does not cover the launch fee.
    error InsufficientValue();
    /// @notice A buy's recipient may not be the token's pool (it would trip the seeding unlock) or the launchpad.
    error InvalidTo();
    error CreatorFeeTooHigh();
    /// @notice The plugin could never pass fees on: the zero address, the launchpad, the migrator, the new token,
    ///         or another launch token.
    error InvalidPlugin();
    /// @notice pluginData was given for a plugin that does not declare IMintMarkFeePlugin, so nothing would ever read
    ///         it: the plugin address is likely mistyped. A plain address (a wallet, a Safe) takes empty pluginData.
    error DataForNonPlugin();
    /// @notice Graduation needs enough gas for the migration plus the vault fallback, so a caller can't starve it.
    error InsufficientGas();
    /// @notice Paying a plain (non-plugin) fee destination failed; the fees stay accrued, collect again later.
    error FeeSendFailed();

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function launchFee() external view returns (uint256);
    /// @notice Platform fees (trade fees and launch fees) accrued in the launchpad and not yet sent to `feeTo`.
    function pendingFees() external view returns (uint256);
    /// @notice `token`'s creator fees accrued in the launchpad and not yet collected to its plugin.
    function pendingCreatorFees(address token) external view returns (uint256);

    function TOTAL_SUPPLY() external view returns (uint256);
    function CURVE_SUPPLY() external view returns (uint256);
    function POOL_SUPPLY() external view returns (uint256);
    function VIRTUAL_TOKENS_0() external view returns (uint256);
    function VIRTUAL_ETH_0() external view returns (uint256);
    function MAX_LAUNCH_FEE() external view returns (uint256);
    /// @notice 1000 (10%): the highest creator fee a token can launch with.
    function MAX_CREATOR_FEE_BPS() external view returns (uint256);

    /// @param creatorFeeBps creator fee on every buy and sell, 0..MAX_CREATOR_FEE_BPS, locked forever
    /// @param plugin where creator fees go, locked forever: any address that can pass them on, so not zero, the
    ///        launchpad, the migrator, the new token or another launch token
    /// @param pluginData passed to the plugin's onLaunch; must be empty unless the plugin declares IMintMarkFeePlugin
    /// @param minTokensOut slippage bound for the creator's first buy (msg.value beyond the launch fee)
    /// @param maxLaunchFee the most launch fee the creator will pay; reverts LaunchFeeAboveMax if it was raised above
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint16 creatorFeeBps,
        address plugin,
        bytes calldata pluginData,
        uint256 minTokensOut,
        uint256 maxLaunchFee
    ) external payable returns (address token);

    /// @param deadline reverts Expired if block.timestamp > deadline
    /// @return ethOut ETH received after both fees
    function sell(address token, uint256 tokensIn, uint256 minEthOut, address to, uint256 deadline)
        external
        returns (uint256 ethOut);

    /// @return tokensOut tokens received
    /// @return platformFee platform fee in wei, included in ethSpent
    /// @return creatorFee creator fee in wei, included in ethSpent
    /// @return ethSpent gross ETH taken (less than ethIn only on the buy that sells out the curve)
    /// @return graduates whether this buy sells out the curve and graduates the token
    function quoteBuy(address token, uint256 ethIn)
        external
        view
        returns (uint256 tokensOut, uint256 platformFee, uint256 creatorFee, uint256 ethSpent, bool graduates);
    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 ethOut, uint256 platformFee, uint256 creatorFee);

    function curves(address token) external view returns (Curve memory);
    function tokensLength() external view returns (uint256);
    function tokenAt(uint256 index) external view returns (address);
    function curvesPage(uint256 start, uint256 count) external view returns (Curve[] memory);

    /// @return wei per whole token, scaled by 1e18
    function spotPrice(address token) external view returns (uint256);
    /// @return spot price times CURVE_SUPPLY, in wei
    function marketCap(address token) external view returns (uint256);
    /// @return tokensSold / CURVE_SUPPLY in basis points
    function progressBps(address token) external view returns (uint256);

    /// @notice Permissionless: sends `pendingFees` to `feeTo`. Fees are never pushed during a trade, so a
    ///         reverting `feeTo` cannot stop trading.
    function collectFees() external returns (uint256 amount);
    /// @notice Permissionless: pays `token`'s accrued creator fees to its plugin. A plugin that declared
    ///         IMintMarkFeePlugin at launch (Curve.pluginHooks) gets onFees with the amount as msg.value; any other
    ///         address gets a plain send. If this reverts, the fees stay accrued. onFees runs inside the launchpad's
    ///         reentrancy guard: a plugin cannot buy, sell or collect from inside it, so buybacks must be separate calls.
    function collectCreatorFees(address token) external returns (uint256 amount);

    function setFeeTo(address feeTo) external;
    /// @notice Setting the zero address is an irreversible renounce.
    function setFeeToSetter(address feeToSetter) external;
    function setLaunchFee(uint256 launchFee) external;
}
