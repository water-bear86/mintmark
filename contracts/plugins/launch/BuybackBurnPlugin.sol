// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ElysiumClock} from "../../libraries/ElysiumClock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMintMarkFeePlugin} from "../../interfaces/IMintMarkFeePlugin.sol";
import {IMigrator} from "../../interfaces/IMigrator.sol";
import {ILaunchTokenExtensions} from "../../interfaces/ILaunchTokenExtensions.sol";
import {ILaunchFeePlugin} from "../../interfaces/plugins/ILaunchFeePlugin.sol";
import {IBuybackBurnPlugin} from "../../interfaces/plugins/IBuybackBurnPlugin.sol";
import {LaunchFeePluginBase} from "./LaunchFeePluginBase.sol";

interface IV2SwapRouter {
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
}

interface IV2PairReserves {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @title BuybackBurnPlugin
/// @notice Spends each launch token's creator fees buying that token and burning it, so its total supply drops.
///         Anyone can run it. Spending is paced by time: at most 0.25% of the ETH-side reserve per hour, plus one
///         full cap for a token's first run or after an idle hour, and at most one run per token per block.
///         Before graduation it buys on the curve; after, on the token's DEX pool through the DEX router.
/// @dev Front-running economics (V13-SPEC §2.2, unchanged by the ETH port): each run's buy raises the price. A
///      trader who buys before the runs and sells after them pays the platform fee and the creator fee `c` on both
///      legs, about 2 * (0.5% + c) of the position, while a full cap (0.25% of the reserve) raises the price by
///      about 0.5%. So the runs a trader sits through must add up to about (0.5% + c) / 0.25% caps before the round
///      trip pays; one cap comes at once, the rest at one cap per hour. Pacing by time, not by block, is what makes
///      that a wait of hours. Runs take no slippage bound, because the pacing is the protection. Each token's ETH is
///      its own; a run only ever spends the running token's balance.
contract BuybackBurnPlugin is IBuybackBurnPlugin, LaunchFeePluginBase {
    /// @inheritdoc IBuybackBurnPlugin
    uint256 public constant CAP_BPS = 25;
    /// @inheritdoc IBuybackBurnPlugin
    uint256 public constant RUN_INTERVAL = 1 hours;
    /// @inheritdoc IBuybackBurnPlugin
    /// @dev Below a gwei the rounded-up fees eat the whole buy and the launchpad reverts ZeroAmount.
    uint256 public constant MIN_RUN_WEI = 1 gwei;
    uint256 private constant _BPS = 10_000;

    struct Buyback {
        uint256 held;
        uint256 totalSpent;
        uint256 totalBurned;
        uint256 nextRunBlock;
        uint256 lastRunAt; // timestamp of the latest run, 0 if the token never ran
    }

    mapping(address token => Buyback) private _buybacks;

    constructor(address launchpad_) LaunchFeePluginBase(launchpad_) {}

    /// @dev Only the launchpad sends ETH outside onFees: the sell-out buy's refund of an unspent offer. It stays in
    ///      the plugin uncredited until the run that received it re-credits nothing — the run's spend accounting
    ///      (held -= ethSpent) already treats the refund as never having left.
    receive() external payable {
        if (msg.sender != address(LAUNCHPAD)) revert StrayEth(msg.sender);
    }

    // ─── Hooks ────────────────────────────────────────────────────────────────

    /// @inheritdoc IMintMarkFeePlugin
    /// @dev Takes no configuration: `data` must be empty.
    function onLaunch(address token, address creator, bytes calldata data) external nonReentrant {
        if (data.length != 0) revert DataNotEmpty();
        _configure(token, creator);
    }

    /// @inheritdoc IMintMarkFeePlugin
    /// @dev Credits `token` with exactly the ETH this call carries. Zero is a no-op. Never buys here: a collection
    ///      runs inside the launchpad's non-reentrant collectCreatorFees, where a curve buy would revert.
    function onFees(address token, uint256 amount) external payable nonReentrant {
        _requireConfigured(token);
        _requireExactValue(amount);
        if (amount == 0) return;
        _buybacks[token].held += amount;
        emit FeesReceived(token, msg.sender, amount);
    }

    // ─── Run ──────────────────────────────────────────────────────────────────

    /// @inheritdoc IBuybackBurnPlugin
    /// @dev The ETH spent is this contract's balance delta over the buy (the launchpad refunds an offer's unspent
    ///      part within the same call; the DEX router takes the offer exactly), so every wei deducted from `held`
    ///      actually left. The pacing state (nextRunBlock, lastRunAt) is written before the buy; a run that reverts
    ///      leaves it untouched. Every state-changing entry point is nonReentrant, and the only external callees are
    ///      the launchpad, the DEX router and the token being bought.
    function run(address token) external nonReentrant returns (uint256 ethSpent, uint256 tokensBurned) {
        _requireConfigured(token);
        Buyback storage buyback = _buybacks[token];
        uint256 currentBlock = ElysiumClock.blockNumber();
        if (currentBlock < buyback.nextRunBlock) revert AlreadyRanThisBlock(token);

        bool graduated = LAUNCHPAD.isGraduated(token);
        uint256 offer = Math.min(buyback.held, _budget(token, graduated, buyback.lastRunAt));
        if (offer < MIN_RUN_WEI) revert NothingToBuy(token);
        buyback.nextRunBlock = currentBlock + 1;
        buyback.lastRunAt = block.timestamp;

        uint256 balanceBefore = address(this).balance;
        uint256 tokensBought;
        if (graduated) {
            IMigrator migrator = IMigrator(LAUNCHPAD.migrator());
            address[] memory path = new address[](2);
            path[0] = migrator.weth();
            path[1] = token;
            uint256[] memory amounts = IV2SwapRouter(migrator.router()).swapExactETHForTokens{value: offer}(
                0, path, address(this), block.timestamp
            );
            tokensBought = amounts[amounts.length - 1];
        } else {
            // On the curve's sell-out buy the launchpad takes only what the last tokens cost and refunds the rest
            // to this contract (see receive()), graduating the token in the same call.
            (tokensBought,) = LAUNCHPAD.buy{value: offer}(token, 0, address(this), block.timestamp);
        }
        ethSpent = balanceBefore - address(this).balance;
        if (ethSpent == 0 || ethSpent > offer) revert BadSpend(offer, ethSpent);

        // Every token this plugin holds is burned: this run's purchase, plus anything sent to it directly.
        tokensBurned = IERC20(token).balanceOf(address(this));
        if (tokensBought == 0 || tokensBurned < tokensBought) revert NothingBought(token);

        buyback.held -= ethSpent; // ethSpent <= offer <= held
        buyback.totalSpent += ethSpent;
        buyback.totalBurned += tokensBurned;
        emit BuybackRun(token, msg.sender, graduated, ethSpent, tokensBurned);

        ILaunchTokenExtensions(token).burn(tokensBurned);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IBuybackBurnPlugin
    function previewRun(address token) external view returns (uint256 ethOffered, bool graduated) {
        graduated = LAUNCHPAD.isGraduated(token);
        Buyback storage buyback = _buybacks[token];
        if (!isConfigured(token) || buyback.held == 0 || ElysiumClock.blockNumber() < buyback.nextRunBlock) {
            return (0, graduated);
        }
        ethOffered = Math.min(buyback.held, _budget(token, graduated, buyback.lastRunAt));
        if (ethOffered < MIN_RUN_WEI) ethOffered = 0;
    }

    /// @inheritdoc IBuybackBurnPlugin
    function totalEthSpent(address token) external view returns (uint256) {
        return _buybacks[token].totalSpent;
    }

    /// @inheritdoc IBuybackBurnPlugin
    function totalTokensBurned(address token) external view returns (uint256) {
        return _buybacks[token].totalBurned;
    }

    /// @inheritdoc IBuybackBurnPlugin
    function nextRunBlock(address token) external view returns (uint256) {
        return _buybacks[token].nextRunBlock;
    }

    /// @inheritdoc IBuybackBurnPlugin
    function lastRunAt(address token) external view returns (uint256) {
        return _buybacks[token].lastRunAt;
    }

    /// @inheritdoc ILaunchFeePlugin
    function ethHeld(address token) external view returns (uint256) {
        return _buybacks[token].held;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev What a run may spend now: the cap prorated by the time since the token's last run,
    ///      cap * min(now - lastRunAt, RUN_INTERVAL) / RUN_INTERVAL rounded down, or the full cap if it never ran.
    ///      Idle time beyond one interval does not accumulate, so no run ever offers more than one cap.
    function _budget(address token, bool graduated, uint256 lastRun) private view returns (uint256 budget) {
        budget = _cap(token, graduated);
        if (lastRun != 0) {
            uint256 elapsed = block.timestamp - lastRun;
            if (elapsed < RUN_INTERVAL) budget = (budget * elapsed) / RUN_INTERVAL;
        }
    }

    /// @dev 0.25% of the ETH-side reserve: the curve's virtual ETH before graduation, the pool's WETH reserve after.
    function _cap(address token, bool graduated) private view returns (uint256) {
        uint256 reserve;
        if (graduated) {
            address pool = LAUNCHPAD.poolOf(token);
            if (pool == address(0)) revert PairNotSet(token);
            (uint112 r0, uint112 r1,) = IV2PairReserves(pool).getReserves();
            reserve = IV2PairReserves(pool).token0() == token ? r1 : r0;
        } else {
            reserve = LAUNCHPAD.virtualEthOf(token);
        }
        return (reserve * CAP_BPS) / _BPS;
    }
}
