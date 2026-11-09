# MintMark v1: ETH launchpad on Linea with a token plugin marketplace (draft)

Status: **contracts built and green**, 2026-10-06: the §3 port is implemented in `contracts/` (102 unit/invariant tests), the PluginRegistry exists with tests, and the full lifecycle passes against the real PancakeSwap V2 factory on a Linea mainnet fork (`LINEA_FORK_RPC_URL=… forge test --match-contract LineaForkTest`). Deploy script: `contracts/script/DeployMintMark.s.sol`. Review round 1 complete (docs/reviews/: one High + one Medium confirmed by both reviewers and fixed, 111 tests + armed invariants + Linea fork green at 515de4f). Still open: a second review round if desired, the Linea Sepolia rehearsal, and §4 phase 5 (site UI). Sections marked **[decided]** are settled; **[proposed]** are
defaults to confirm. This is a port-and-extend of two reviewed codebases we own — the Architex launchpad v1.3
(`~/Development/arc-dex`, V13-SPEC.md, nine review rounds) for the curve + plugin system, and Metapad's
native-ETH quote handling + Uniswap-V2 migrator (`~/metapad/contracts/evm`, fork-tested on Linea) for the money
leg and graduation — not a greenfield build.

## 0. Why

MintMark's differentiator over a plain pump clone is the **token plugin marketplace**: at launch a creator picks
where their 0–10% creator fee goes — their wallet, a split, buyback-and-burn, holder dividends, or any plugin an
author has published. Plugins are safe by interface (they can never block a trade or touch more than their
accrued fees), so the marketplace can be open to third-party authors with curation as a badge, not a gate. The
curve economics are where launchpad revenue lives (pump.fun's fortune is curve fees), so v1 ships plugins on the
curve phase and leaves post-graduation fee streaming to v2.

## 1. Facts (probed / sourced 2026-10-06)

- **Uniswap v4 is NOT on Linea** and canonical Uniswap v3 isn't either (official deployments pages, checked
  2026-10-06). The Architex v1.4 hook architecture therefore cannot port; the lander's "graduates to Uniswap"
  copy must change (see D3).
- **PancakeSwap V2 is live on Linea** and already fork-verified in Metapad's repo: router
  `0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb` (probed: `factory()` = `0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E`),
  pair init-code hash `0x5722…74d2d` (metapad `dexes.ts`, ForkMigration-tested), indexed by DexScreener (`linea`
  slug).
- **Canonical WETH on Linea**: `0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f` (read from the router, symbol "WETH").
- **Block cadence measured ~10s** (302s over 30 blocks via linea-rpc.publicnode.com) — re-measure at deploy;
  anti-snipe windows count blocks and were tuned for Arc's sub-second blocks, so the constants do not carry over.
- Deterministic CREATE2 deployer (`0x4e59b448…956C`) present on Linea. Chain id 59144.

## 2. Decisions

- **D1 [decided]: quote in native ETH.** Buys send `msg.value`, sells pay out ETH — no approvals anywhere in the
  trading UX (the pump.fun bar). Internally the money leg follows Metapad's reviewed pattern (nonReentrant,
  exact-amount effects before interactions, pull-payment `claimable` for everything owed), not balance reads.
  WETH appears only inside graduation (the migrator wraps).
- **D2 [proposed]: curve constants.** Architex's shape (every curve identical, 16× price rise), re-denominated:
  TOTAL_SUPPLY 1B (18 dp), CURVE_SUPPLY 800M, POOL_SUPPLY 200M, VIRTUAL_TOKENS_0 1,066,666,667e18,
  VIRTUAL_ETH_0 = 5/3 ETH → a curve raises **5 ETH** and opens its pool at 5 ETH × 200M tokens
  (≈ $20k raise / $80k graduation cap at $4k ETH). Platform fee 0.5% per trade; creator fee 0–10% locked at
  launch, both in ETH, rounded up, accrued never pushed. Launch fee ≤ 0.01 ETH, owner-settable below the cap.
- **D3 [decided]: graduation v1 = PancakeSwap V2 on Linea, LP burned.** The sell-out buy wraps the raise to WETH
  and seeds token/WETH on Pancake V2 through a Metapad-style migrator (its `UniswapV2Migrator` is fork-tested on
  this exact router), LP to `0xdead`. Aggregators and DexScreener reach Pancake V2 natively — the documented
  failure of Architex v1.3's private pools ("only our router can trade them") is what this avoids. The lander's
  "Uniswap" line becomes "liquidity locked forever on a public DEX" (or names PancakeSwap). **v2 roadmap:**
  post-graduation fee streaming via a full-range v3-style position held by an ownerless FeeVault (the
  "post-grad creator fees" item in metapad's launchpad-feature-catalog) — only after v1 is live.
- **D4 [decided]: plugin interface = Architex's, re-legged for ETH.** `IMintMarkFeePlugin is IERC165`:
  `onLaunch(token, creator, bytes data)` (once, inside createToken, write-once config) and
  `onFees(token, amount) payable` with the invariant **msg.value == amount** — credits are always backed by ETH
  received in the same call (the ETH analogue of V13's exact-pull check). Containment carries over verbatim:
  fees ACCRUE during trades (`pendingFees`, `pendingCreatorFees[token]`); trades never call a plugin or feeTo;
  `collectCreatorFees(token)` is permissionless and push-pays the plugin (or plain-transfers to a non-plugin
  address); a reverting plugin reverts only its own collection, never a trade, launch or graduation. Plugins
  that could never pass fees on (the token, its pair, the router, WETH, another curve's token) are rejected at
  launch, as in V13.
- **D5 [decided]: the marketplace is permissionless by interface, curated by registry.** Any address can be a
  plugin (a bare wallet included — that's the "pay me" default). A separate **PluginRegistry** holds listings:
  `{plugin, author, name, metadataURI, authorFeeBps (self-declared disclosure), verified}` — `verified` set only
  by the curator (us, after review), everything else self-service for authors (one listing fee, [proposed]
  0.005 ETH). The registry gates NOTHING on-chain; the site renders badges, warnings and the browse/pick UI
  from it. This is metapad's docs/feature-modules.md marketplace with Architex's safe-by-interface containment
  instead of an allowlist — the interface already makes the worst case "a plugin wastes its own fee slice".
- **D6 [decided]: v1 plugin set**, ported from arc-dex (USDC→ETH leg, 6→18 dp): SplitPlugin (fixed shares to
  N addresses), BuybackBurnPlugin (buys the token on its own curve and burns), HolderDistributionPlugin
  (dividends to holders), ComboPlugin (composes the others). The charity-split idea from metapad's Solana v2
  (`charity token plugin`) folds into SplitPlugin presets on the site.
- **D7 [decided]: repo & names.** Contracts live in this repo (`contracts/`, Foundry): `MintMarkLaunchpad`,
  `LaunchToken`, `MintMarkMigrator`, `PluginRegistry`, `plugins/*`, interfaces under `contracts/src/interfaces`.
  House review convention applies before any deploy: at least two independent review rounds with findings fixed
  or accepted in-spec, then a Linea Sepolia rehearsal, then the mainnet runbook (owner deploys with a Ledger).

## 3. Port map

| Source (reviewed) | Becomes | Change |
| --- | --- | --- |
| arc-dex `ArchitexLaunchpad.sol` (v1.3) | `MintMarkLaunchpad.sol` | USDC pulls → `msg.value`/`sendValue` (Metapad pattern); 6→18 dp constants (D2); graduation → migrator call (D3); plugin pay leg → payable push (D4); drop Arc-trap comments/logic |
| arc-dex `LaunchToken.sol` (v1.3) | `LaunchToken.sol` | keep `pull` (approval-free sells), burn; drop USDC-dividend streaming (v2) |
| metapad `UniswapV2Migrator.sol` | `MintMarkMigrator.sol` | single-launchpad form; Pancake V2 Linea router + init hash baked in; WETH wrap |
| arc-dex `plugins/launch/*` (Split, BuybackBurn, HolderDistribution, Combo) | `plugins/*` | ETH leg; `onFees` payable; buyback plugin buys via the ETH curve |
| new | `PluginRegistry.sol` | D5; small, no privileges beyond `verified` |
| arc-dex V13 test battery + metapad ForkMigration | `test/*` | port the invariants (fee solvency, sells-never-blocked, graduation atomicity) + review-regression cases that still apply; Linea fork test for graduation |

Dropped from the port: LaunchPair/LaunchPairFactory/LaunchRouter (own-pool suite — superseded by D3),
everything in contracts-v14 (v4 hook — no v4 on Linea; revisit if Uniswap ships v4 there).

## 4. Workplan

0. ~~Probe Linea~~ (done, §1) — re-run at deploy time (block cadence, router liveness).
1. Scaffold `contracts/` (Foundry, OZ pin matching arc-dex), vendor the §3 sources, rename, compile.
2. The two surgical changes, each with its invariant tests before moving on: the ETH money leg, then the
   migrator graduation (Linea fork test against the real Pancake factory).
3. PluginRegistry + the four plugins, with the V13 plugin containment tests re-pointed at the ETH leg.
4. Review rounds (house convention), fix/accept, Linea Sepolia rehearsal end-to-end.
5. Site: launch form (name/ticker/image, creator fee, **plugin picker fed by the registry**), token page with
   live curve, marketplace browse page, author listing flow. Replace the simulated market.
6. Mainnet runbook: deploy order, verify, canary launch, switch the site.

## 5. Open questions for the owner

- D2's raise size (5 ETH ≈ $20k) and the 0.5%/10%/launch-fee knobs.
- Graduation venue: Pancake V2 is the proven default; Linea-native ve(3,3) DEXes (Etherex, Lynex) could be
  partners instead, but each needs the metapad-style fork verification from scratch.
- **Multi-chain / Robinhood: shelved (2026-10-06).** The stack ports to any fork-verified V2 chain in about a
  day (metapad dexes.ts is the catalog: swap the migrator's router + pair-code hash, run the fork test). V2
  pools need nobody's permission. Robinhood Chain is the exception — no verified V2 DEX there; the real path is
  reviving Architex v1.4's Uniswap-v4 hook (post-grad fees, but a USDC→ETH re-leg + reviews, and Uniswap-app
  routing needs their hook allowlist; aggregators route without it) — deferred until Linea is live and the
  idea earns its own project.
- Lander copy: replace "Uniswap" with the D3 wording.
- Whether the plugin author listing fee exists at all, and the curator key (EOA now, multisig later).
