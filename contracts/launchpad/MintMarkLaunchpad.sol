// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "../interfaces/IMintMarkLaunchpad.sol";
import "../interfaces/IMintMarkFeePlugin.sol";
import "../interfaces/IMigrator.sol";
import "../interfaces/ILaunchToken.sol";
import "./GraduationVault.sol";
import "./LaunchToken.sol";

/// @title MintMarkLaunchpad
/// @notice Bonding-curve token launches quoted in native ETH, with per-token creator fees routed to plugins,
///         graduating into a public V2 DEX pool with the LP burned (docs/PLUGIN-MARKETPLACE-SPEC.md). An ETH port
///         of the Architex launchpad v1.3: its V13-SPEC rules hold wherever this contract does not change them.
///
/// Curves: every curve is identical. Constant product on virtual reserves:
///   k = virtualEth * virtualTokens  (recomputed every trade, never stored)
///   real ETH held for a curve = virtualEth - VIRTUAL_ETH_0
///
/// Fees: a 0.5% platform fee and the token's creator fee (0-10%, locked at launch) on every buy and sell, both in
/// ETH, both rounded up. They are ACCRUED here (`pendingFees`, `pendingCreatorFees[token]`) and never pushed during
/// a trade: `collectFees()` sends the platform's to `feeTo`, `collectCreatorFees(token)` pays the token's plugin,
/// both permissionless. A trade never calls a plugin or `feeTo`, so neither can stop a trade, a launch or a
/// graduation. ETH held == pendingFees + Σ pendingCreatorFees + Σ(virtualEth - VIRTUAL_ETH_0) over live curves,
/// to the wei (absent forced ETH; receive/fallback revert).
///
/// Graduation: the buy that sells the last curve token sends POOL_SUPPLY tokens and exactly
/// `virtualEth - VIRTUAL_ETH_0` ETH (that curve's, never balanceOf) through the migrator, which wraps the ETH,
/// seeds the token/WETH pool on the DEX and burns the LP — atomically inside the buy. A failing migration can't
/// block the sell-out: it runs gas-capped in try/catch (Metapad's reviewed pattern) and falls back to an ownerless
/// GraduationVault anyone can retry from.
///
/// @dev `name`, `symbol`, `metadataURI` are untrusted bytes: length limits only, no charset validation, no HTML
///      escaping. Rendering rules are the site's problem.
contract MintMarkLaunchpad is IMintMarkLaunchpad, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ─── Constants ───────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpad
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @inheritdoc IMintMarkLaunchpad
    uint256 public constant CURVE_SUPPLY = 800_000_000e18;
    /// @inheritdoc IMintMarkLaunchpad
    uint256 public constant POOL_SUPPLY = 200_000_000e18;
    /// @inheritdoc IMintMarkLaunchpad
    uint256 public constant VIRTUAL_TOKENS_0 = 1_066_666_667e18;
    /// @inheritdoc IMintMarkLaunchpad
    /// @dev Calibrated for exactly 30 native coins of net liquidity on a fresh single-fill curve:
    ///      V0 = 30e18 * (VIRTUAL_TOKENS_0 - CURVE_SUPPLY) / CURVE_SUPPLY.
    ///      Preserves the token allocation and approximately 16x price rise. Recomputed k and ceiling
    ///      rounding can add dust after multiple trades; 30 is the fresh-curve baseline, not a hard cap.
    uint256 public constant VIRTUAL_ETH_0 = 10_000_000_012_500_000_000;
    /// @inheritdoc IMintMarkLaunchpadLite
    uint256 public constant FEE_BPS = 50;
    /// @inheritdoc IMintMarkLaunchpad
    uint256 public constant MAX_LAUNCH_FEE = 0.01 ether;
    /// @inheritdoc IMintMarkLaunchpad
    uint256 public constant MAX_CREATOR_FEE_BPS = 1000;

    /// @notice Gas handed to the migrator: covers creating a V2 pair (~2.5M) with headroom for heavier forks.
    uint256 public constant MIGRATION_GAS = 5_000_000;
    /// @notice Gas kept back for the fallback: creating a GraduationVault and moving the liquidity into it
    ///         (the token transfer runs the dividend accounting, so this is roomier than a plain ERC-20 move).
    uint256 internal constant VAULT_GAS = 900_000;

    uint256 private constant _BPS = 10_000;

    // ─── Immutables ──────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpadLite
    address public immutable migrator;

    // ─── Mutable admin ───────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpad
    address public feeTo;
    /// @inheritdoc IMintMarkLaunchpad
    address public feeToSetter;
    /// @inheritdoc IMintMarkLaunchpad
    uint256 public launchFee;

    // ─── Fee accrual ─────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpad
    uint256 public pendingFees;
    /// @inheritdoc IMintMarkLaunchpad
    mapping(address => uint256) public pendingCreatorFees;

    // ─── Token registry ──────────────────────────────────────────────────────

    mapping(address => Curve) private _curves;
    address[] private _tokens;

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address _migrator, address _feeTo, address _feeToSetter, uint256 _launchFee) {
        if (_migrator == address(0)) revert ZeroAddress();
        if (_feeTo == address(0)) revert ZeroAddress();
        if (_feeToSetter == address(0)) revert ZeroAddress();
        if (_launchFee > MAX_LAUNCH_FEE) revert LaunchFeeTooHigh();
        migrator = _migrator;
        feeTo = _feeTo;
        feeToSetter = _feeToSetter;
        launchFee = _launchFee;
    }

    // ─── No stray ETH ────────────────────────────────────────────────────────

    receive() external payable { revert(); }
    fallback() external payable { revert(); }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpad
    /// @notice Only callable by feeToSetter. Rejects the zero address and the launchpad itself.
    function setFeeTo(address _feeTo) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        if (_feeTo == address(0)) revert ZeroAddress();
        if (_feeTo == address(this)) revert ZeroAddress();
        feeTo = _feeTo;
        emit FeeToUpdated(_feeTo);
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @notice Only callable by the current feeToSetter. Setting to address(0) is an IRREVERSIBLE RENOUNCE: the fee
    ///         admin role is permanently abandoned and feeTo can never be changed again.
    function setFeeToSetter(address _feeToSetter) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        // address(0) is allowed here as an explicit irreversible renounce.
        feeToSetter = _feeToSetter;
        emit FeeToSetterUpdated(_feeToSetter);
    }

    /// @inheritdoc IMintMarkLaunchpad
    function setLaunchFee(uint256 _launchFee) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        if (_launchFee > MAX_LAUNCH_FEE) revert LaunchFeeTooHigh();
        launchFee = _launchFee;
        emit LaunchFeeUpdated(_launchFee);
    }

    // ─── Fee collection ──────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpad
    /// @notice Permissionless: sends `pendingFees` to `feeTo`. A reverting feeTo reverts only this call, never a trade.
    function collectFees() external nonReentrant returns (uint256 amount) {
        amount = pendingFees;
        if (amount == 0) return 0;
        pendingFees = 0;
        address to = feeTo;
        emit FeesCollected(to, amount);
        Address.sendValue(payable(to), amount);
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @dev The accrual is zeroed before the send, so a revert anywhere restores it. For a plugin that declared
    ///      IMintMarkFeePlugin at launch (the stored decision, never re-probed, so a plugin whose ERC-165 answer
    ///      later changes cannot be paid in a way it does not credit): call onFees carrying exactly `amount` as
    ///      msg.value — a credit is therefore always backed by ETH received in the same call. Every other address
    ///      gets a plain send, which reverts (and keeps the fees accrued) if it cannot receive ETH.
    function collectCreatorFees(address token) external nonReentrant returns (uint256 amount) {
        Curve storage c = _curves[token];
        address plugin = c.plugin;
        if (plugin == address(0)) revert UnknownToken();
        amount = pendingCreatorFees[token];
        if (amount == 0) return 0;
        pendingCreatorFees[token] = 0;
        emit CreatorFeesCollected(token, plugin, amount);

        if (c.pluginHooks) {
            IMintMarkFeePlugin(plugin).onFees{value: amount}(token, amount);
        } else {
            Address.sendValue(payable(plugin), amount);
        }
    }

    // ─── Token creation ──────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpad
    /// @notice Deploys a LaunchToken, registers the curve against its predicted DEX pool, lets the plugin configure
    ///         itself (onLaunch, only if it declares IMintMarkFeePlugin), then spends whatever msg.value exceeds the
    ///         launch fee as the creator's first buy in the same transaction (anti-snipe). The creator's first buy
    ///         pays the creator fee like any other. Reverts InvalidPlugin for a plugin that could never pass fees
    ///         on, and DataForNonPlugin for pluginData given to an address that does not declare IMintMarkFeePlugin.
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint16 creatorFeeBps,
        address plugin,
        bytes calldata pluginData,
        uint256 minTokensOut,
        uint256 maxLaunchFee
    ) external payable nonReentrant returns (address token) {
        // ── Validate ──────────────────────────────────────────────────────────
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 10) revert InvalidSymbol();
        if (bytes(metadataURI).length > 256) revert InvalidMetadata();
        if (creatorFeeBps > MAX_CREATOR_FEE_BPS) revert CreatorFeeTooHigh();
        // Paying itself would leave the fees in the launchpad untracked. The rest of the plugin checks need the new
        // token's address (below). The dead address stays allowed: burning the fees is a choice.
        if (plugin == address(0) || plugin == address(this)) revert InvalidPlugin();

        // ── Accrue launch fee (the rest of msg.value is the first buy) ────────
        uint256 fee = launchFee;
        if (fee > maxLaunchFee) revert LaunchFeeAboveMax();
        if (msg.value < fee) revert InsufficientValue();
        if (fee > 0) pendingFees += fee;

        // ── Deploy token, predict its pool ────────────────────────────────────
        LaunchToken lt = new LaunchToken(name, symbol);
        token = address(lt);
        address pool = IMigrator(migrator).poolFor(token);
        lt.initPool(pool);

        // Addresses that could never pass fees on. The migrator and the predicted pool would strand them (a V2 pair
        // cannot receive ETH), WETH would silently convert them into WETH owned by this launchpad (its receive()
        // deposits to msg.sender — review #1 L3), the DEX router and factory would strand or refuse them, and so
        // would this token or any other launch token (the curve registry knows them all: every registered curve has
        // a creator). The new token's and its pool's addresses are predictable.
        IMigrator m = IMigrator(migrator);
        if (
            plugin == migrator || plugin == token || plugin == pool || plugin == m.weth() || plugin == m.router()
                || plugin == m.dexFactory() || _curves[plugin].creator != address(0)
        ) revert InvalidPlugin();

        // ── Register curve ───────────────────────────────────────────────────
        // Hooks or plain address is decided here, once, and stored: onFees is called for this token exactly when
        // onLaunch was.
        bool hooks = _hasHooks(plugin);
        // Configuration for an address that turns out not to be a plugin would be silently dropped: a mistyped plugin
        // address would launch fine and take every fee.
        if (!hooks && pluginData.length != 0) revert DataForNonPlugin();
        _curves[token] = Curve({
            token: token,
            creator: msg.sender,
            pool: pool,
            virtualEth: VIRTUAL_ETH_0.toUint128(),
            virtualTokens: VIRTUAL_TOKENS_0.toUint128(),
            tokensSold: 0,
            createdAt: uint64(block.timestamp),
            graduated: false,
            creatorFeeBps: creatorFeeBps,
            pluginHooks: hooks,
            plugin: plugin,
            metadataURI: metadataURI
        });
        _tokens.push(token);

        emit TokenCreated(token, msg.sender, plugin, pool, creatorFeeBps, name, symbol, metadataURI);

        // ── Plugin configuration: after registration, before the first buy ────
        // All remaining gas is forwarded (a large Split or Combo configuration costs over 1M). A reverting onLaunch
        // reverts the launch (the creator's own choice of plugin).
        if (hooks) {
            IMintMarkFeePlugin(plugin).onLaunch(token, msg.sender, pluginData);
        }

        // ── Optional creator first buy (anti-snipe; uses internal _buy) ───────
        // msg.value == fee skips entirely and does NOT revert ZeroAmount.
        uint256 initialBuy = msg.value - fee;
        if (initialBuy > 0) {
            _buy(token, initialBuy, minTokensOut, msg.sender);
        }
    }

    // ─── Trading ─────────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpadLite
    /// @notice Buy tokens from the curve with msg.value. On the sell-out buy, spends only what the remaining tokens
    ///         cost and refunds the rest. Graduates atomically when the last token is sold. Reverts Expired after
    ///         `deadline`.
    function buy(address token, uint256 minTokensOut, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut, uint256 ethSpent)
    {
        if (block.timestamp > deadline) revert Expired();
        return _buy(token, msg.value, minTokensOut, to);
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @notice Sell tokens into the curve. The token's `pull` moves them back without an ERC-20 approval, always from
    ///         msg.sender. `to` is the ETH recipient; `trader` in the event is always msg.sender. Reverts Expired
    ///         after `deadline`.
    function sell(address token, uint256 tokensIn, uint256 minEthOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (block.timestamp > deadline) revert Expired();
        Curve storage c = _curves[token];
        if (c.token == address(0)) revert UnknownToken();
        if (c.graduated) revert CurveGraduated();

        uint256 vEth = c.virtualEth;
        uint256 vTokens = c.virtualTokens;

        // ── Guards + math, the one path quoteSell also takes ──────────────────
        (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 out) = _sellQuote(c, tokensIn);
        ethOut = out;
        if (ethOut < minEthOut) revert SlippageExceeded();

        // ── Effects ──────────────────────────────────────────────────────────
        uint256 newVEth = vEth - gross;
        uint256 newVTokens = vTokens + tokensIn;
        c.virtualEth = newVEth.toUint128();
        c.virtualTokens = newVTokens.toUint128();
        c.tokensSold = (uint256(c.tokensSold) - tokensIn).toUint128();

        // Accrue fees (never pushed: neither feeTo nor the plugin can block a sell)
        pendingFees += platformFee;
        if (creatorFee != 0) pendingCreatorFees[token] += creatorFee;

        emit Trade(token, msg.sender, false, gross, tokensIn, platformFee, creatorFee, newVEth, newVTokens);

        // ── Interactions ─────────────────────────────────────────────────────
        // Always msg.sender as the seller, never a parameter; the token only lets the launchpad pull into itself.
        ILaunchToken(token).pull(msg.sender, address(this), tokensIn);
        Address.sendValue(payable(to), ethOut);
    }

    // ─── Internal buy logic ──────────────────────────────────────────────────

    /// @dev Shared by buy() and createToken(). The nonReentrant guard is held by the caller. No deadline here:
    ///      buy() checks its own, and createToken's first buy runs in the launch transaction itself.
    ///      `offered` is ETH that has already arrived with the call; the unspent part (only the sell-out buy spends
    ///      less) is refunded to msg.sender at the very end, after any graduation.
    function _buy(address token, uint256 offered, uint256 minTokensOut, address to)
        internal
        returns (uint256 tokensOut, uint256 ethSpent)
    {
        Curve storage c = _curves[token];
        if (c.token == address(0)) revert UnknownToken();
        if (c.graduated) revert CurveGraduated();
        if (offered == 0) revert ZeroAmount();

        uint256 vEth = c.virtualEth;
        uint256 vTokens = c.virtualTokens;
        uint256 sold = c.tokensSold;

        // ── Buy math (shared with quoteBuy) ──────────────────────────────────
        uint256 platformFee;
        uint256 creatorFee;
        bool graduates;
        (tokensOut, platformFee, creatorFee, ethSpent, graduates) =
            _calcBuy(vEth, vTokens, CURVE_SUPPLY - sold, offered, c.creatorFeeBps);

        if (tokensOut < minTokensOut) revert SlippageExceeded();
        // The buyer picks `to`, and the launchpad is `from` of this payout: delivering into the pool would trip the
        // token's seeding unlock and hand the pool to a squatter (review #1 H1), and delivering into the launchpad
        // itself would corrupt the curve inventory. Both are rejected; the token's own lock is the second line.
        if (to == c.pool || to == address(this)) revert InvalidTo();

        // ── Effects ──────────────────────────────────────────────────────────
        uint256 newVEth = vEth + (ethSpent - platformFee - creatorFee);
        uint256 newVTokens = vTokens - tokensOut;
        c.virtualEth = newVEth.toUint128();
        c.virtualTokens = newVTokens.toUint128();
        c.tokensSold = (sold + tokensOut).toUint128();

        // Accrue fees (never pushed: neither feeTo nor the plugin can block a buy or graduation)
        pendingFees += platformFee;
        if (creatorFee != 0) pendingCreatorFees[token] += creatorFee;

        emit Trade(token, msg.sender, true, ethSpent, tokensOut, platformFee, creatorFee, newVEth, newVTokens);

        // ── Interactions ─────────────────────────────────────────────────────
        IERC20(token).safeTransfer(to, tokensOut);

        // ── Graduation (atomic inside the sell-out buy) ──────────────────────
        if (graduates) {
            _graduate(c);
        }

        // ── Refund the unspent offer (sell-out buy only; ethSpent <= offered) ─
        uint256 refund = offered - ethSpent;
        if (refund != 0) Address.sendValue(payable(msg.sender), refund);
    }

    // ─── Graduation ──────────────────────────────────────────────────────────

    /// @dev Sends POOL_SUPPLY tokens and exactly `virtualEth - VIRTUAL_ETH_0` ETH (this curve's raise, never
    ///      balanceOf) through the migrator, which wraps, seeds the DEX pool and burns the LP. The migration runs
    ///      gas-capped in try/catch so a failing DEX cannot block the sell-out buy: on failure the liquidity parks
    ///      in an ownerless GraduationVault anyone can retry from (Metapad's reviewed pattern). The gas floor stops
    ///      a caller from starving the migration into the fallback on purpose.
    function _graduate(Curve storage c) internal {
        address token = c.token;
        uint256 ethSeeded = uint256(c.virtualEth) - VIRTUAL_ETH_0;
        c.graduated = true;

        if (gasleft() < MIGRATION_GAS * 64 / 63 + VAULT_GAS) revert InsufficientGas();
        IERC20(token).forceApprove(migrator, POOL_SUPPLY);
        try IMigrator(migrator).migrate{value: ethSeeded, gas: MIGRATION_GAS}(token, POOL_SUPPLY) returns (
            address pool, uint256 liquidity
        ) {
            emit Graduated(token, pool, ethSeeded, POOL_SUPPLY, liquidity);
        } catch {
            _parkInVault(token, ethSeeded);
        }
    }

    /// @dev Don't block the sell-out and don't hand liquidity to anyone: park it where only the pool can receive it.
    function _parkInVault(address token, uint256 ethSeeded) internal {
        IERC20(token).forceApprove(migrator, 0);
        address vault = address(new GraduationVault{salt: bytes32(uint256(uint160(token)))}(token, migrator));
        LaunchToken(token).setVault(vault);
        IERC20(token).safeTransfer(vault, POOL_SUPPLY);
        Address.sendValue(payable(vault), ethSeeded);
        emit MigrationFailed(token, vault);
        emit Graduated(token, vault, ethSeeded, POOL_SUPPLY, 0);
    }

    // ─── Core math — pure, shared by trades and quotes ───────────────────────

    /// @dev Buy math (V13-SPEC §5, unchanged). All rounding favours the curve; ethSpent is ALWAYS <= ethIn.
    ///      Normal buy: platformFee = ceil(ethIn*50/1e4), creatorFee = ceil(ethIn*c/1e4), net = ethIn - both.
    ///      Sell-out buy: net = what the remaining tokens cost; gross = net + ceil(net*(50+c)/(1e4-(50+c))) capped at
    ///      ethIn; totalFee = ethSpent - net, split platformFee = ceil(totalFee*50/(50+c)), creatorFee = the rest.
    function _calcBuy(uint256 vEth, uint256 vTokens, uint256 remaining, uint256 ethIn, uint256 creatorFeeBps)
        internal
        pure
        returns (uint256 tokensOut, uint256 platformFee, uint256 creatorFee, uint256 ethSpent, bool graduates)
    {
        // k recomputed fresh every trade, never stored
        uint256 k = vEth * vTokens;

        platformFee = _divCeil(ethIn * FEE_BPS, _BPS);
        creatorFee = _divCeil(ethIn * creatorFeeBps, _BPS);
        // Fees that eat the whole input buy nothing (and would underflow `net`).
        if (platformFee + creatorFee >= ethIn) revert ZeroAmount();
        uint256 net = ethIn - platformFee - creatorFee;

        // tokensOut = vTokens - ceil(k / (vEth + net))
        tokensOut = vTokens - _divCeil(k, vEth + net);

        if (tokensOut == 0) revert ZeroAmount();

        if (tokensOut >= remaining) {
            // ── Exact-fill: only take what's needed for the remaining tokens ──
            uint256 feeBps = FEE_BPS + creatorFeeBps;
            // net = ceil(k / (vTokens - remaining)) - vEth. It is <= the net offered above, so the fee below is >= 0.
            net = _divCeil(k, vTokens - remaining) - vEth;
            // ethSpent = min(ethIn, net + ceil(net * feeBps / (10_000 - feeBps))): never more than offered. The cap
            // cannot actually bind (the rounded-up normal fees on ethIn already cover that ceil for the larger offered
            // net), but it stays as the spec writes it. The fees are whatever was taken beyond `net`, so every wei
            // credited was received.
            uint256 gross = net + _divCeil(net * feeBps, _BPS - feeBps);
            ethSpent = gross < ethIn ? gross : ethIn;
            uint256 totalFee = ethSpent - net;
            platformFee = _divCeil(totalFee * FEE_BPS, feeBps);
            creatorFee = totalFee - platformFee;
            tokensOut = remaining;
            graduates = true;
        } else {
            ethSpent = ethIn;
        }
    }

    /// @dev Sell math. gross = vEth - ceil(k / (vTokens + tokensIn)); both fees = ceil(gross * bps / 1e4).
    ///      All rounding favours the curve.
    function _calcSell(uint256 vEth, uint256 vTokens, uint256 tokensIn, uint256 creatorFeeBps)
        internal
        pure
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee)
    {
        uint256 k = vEth * vTokens;
        gross = vEth - _divCeil(k, vTokens + tokensIn);
        platformFee = _divCeil(gross * FEE_BPS, _BPS);
        creatorFee = _divCeil(gross * creatorFeeBps, _BPS);
    }

    /// @dev Every check a sell makes before it touches state, so a quote can never promise what a sell would refuse:
    ///      nothing to sell, more than the curve has sold, or dust whose proceeds the fees consume.
    function _sellQuote(Curve storage c, uint256 tokensIn)
        internal
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 ethOut)
    {
        if (tokensIn == 0) revert ZeroAmount();
        if (tokensIn > uint256(c.tokensSold)) revert ExceedsSold();
        (gross, platformFee, creatorFee) = _calcSell(c.virtualEth, c.virtualTokens, tokensIn, c.creatorFeeBps);
        if (platformFee + creatorFee >= gross) revert ZeroAmount();
        ethOut = gross - platformFee - creatorFee;
    }

    // ─── View functions ──────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkLaunchpad
    /// @dev Reverts UnknownToken for an address that was never launched here.
    function curves(address token) external view returns (Curve memory) {
        if (_curves[token].token == address(0)) revert UnknownToken();
        return _curves[token];
    }

    /// @inheritdoc IMintMarkLaunchpadLite
    function pluginOf(address token) external view returns (address) {
        return _curves[token].plugin;
    }

    /// @inheritdoc IMintMarkLaunchpadLite
    function creatorOf(address token) external view returns (address) {
        return _curves[token].creator;
    }

    /// @inheritdoc IMintMarkLaunchpadLite
    function creatorFeeBpsOf(address token) external view returns (uint16) {
        return _curves[token].creatorFeeBps;
    }

    /// @inheritdoc IMintMarkLaunchpadLite
    function poolOf(address token) external view returns (address) {
        return _curves[token].pool;
    }

    /// @inheritdoc IMintMarkLaunchpadLite
    function isGraduated(address token) external view returns (bool) {
        return _curves[token].graduated;
    }

    /// @inheritdoc IMintMarkLaunchpadLite
    function virtualEthOf(address token) external view returns (uint256) {
        return _curves[token].virtualEth;
    }

    /// @inheritdoc IMintMarkLaunchpad
    function tokensLength() external view returns (uint256) {
        return _tokens.length;
    }

    /// @inheritdoc IMintMarkLaunchpad
    function tokenAt(uint256 index) external view returns (address) {
        return _tokens[index];
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @param count Clamped to 100 to bound gas.
    function curvesPage(uint256 start, uint256 count) external view returns (Curve[] memory result) {
        if (count > 100) count = 100;
        uint256 len = _tokens.length;
        if (start >= len) return new Curve[](0);
        uint256 end = start + count;
        if (end > len) end = len;
        result = new Curve[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = _curves[_tokens[i]];
        }
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @notice Same code path as buy().
    function quoteBuy(address token, uint256 ethIn)
        external
        view
        returns (uint256 tokensOut, uint256 platformFee, uint256 creatorFee, uint256 ethSpent, bool graduates)
    {
        Curve storage c = _curves[token];
        if (c.token == address(0)) revert UnknownToken();
        if (c.graduated) revert CurveGraduated();
        if (ethIn == 0) revert ZeroAmount();

        uint256 remaining = CURVE_SUPPLY - uint256(c.tokensSold);
        return _calcBuy(c.virtualEth, c.virtualTokens, remaining, ethIn, c.creatorFeeBps);
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @notice Same code path as sell(). `Trade.ethAmount` on a sell is gross (the seller receives ethOut).
    function quoteSell(address token, uint256 tokensIn)
        external
        view
        returns (uint256 ethOut, uint256 platformFee, uint256 creatorFee)
    {
        Curve storage c = _curves[token];
        if (c.token == address(0)) revert UnknownToken();
        if (c.graduated) revert CurveGraduated();
        (, platformFee, creatorFee, ethOut) = _sellQuote(c, tokensIn);
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @return wei per whole token, scaled by 1e18: virtualEth * 1e36 / virtualTokens.
    function spotPrice(address token) external view returns (uint256) {
        Curve storage c = _curves[token];
        if (c.token == address(0)) revert UnknownToken();
        // After graduation this is the curve's final price (the reserves are frozen), not a revert:
        // lists and indexers read it for every token.
        return uint256(c.virtualEth) * 1e36 / uint256(c.virtualTokens);
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @return virtualEth * CURVE_SUPPLY / virtualTokens, in wei.
    function marketCap(address token) external view returns (uint256) {
        Curve storage c = _curves[token];
        if (c.token == address(0)) revert UnknownToken();
        return uint256(c.virtualEth) * CURVE_SUPPLY / uint256(c.virtualTokens);
    }

    /// @inheritdoc IMintMarkLaunchpad
    /// @return tokensSold * 10_000 / CURVE_SUPPLY (multiply first to avoid truncation to 0)
    function progressBps(address token) external view returns (uint256) {
        Curve storage c = _curves[token];
        if (c.token == address(0)) revert UnknownToken();
        return uint256(c.tokensSold) * _BPS / CURVE_SUPPLY;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Whether `plugin` declares IMintMarkFeePlugin through ERC-165 (OpenZeppelin ERC165Checker: staticcalls
    ///      capped at 30k gas; an EOA, or a contract that does not answer, is a plain address). Asked once, at launch.
    function _hasHooks(address plugin) private view returns (bool) {
        return ERC165Checker.supportsInterface(plugin, type(IMintMarkFeePlugin).interfaceId);
    }

    /// @dev Ceiling division: ceil(a / b). Reverts on b == 0.
    function _divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
