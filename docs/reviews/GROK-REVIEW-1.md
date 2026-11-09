# Grok review #1 — MintMark ETH port (2026-10-06)

Independent adversarial pass by Grok Build (session 91090f5f-49c3-4de6-992c-c2882f9f415d, 30m44s, max rigor),
run against commit b1b094c with PoC tests executed in-tree. Transcribed verbatim in substance; resolutions
added by the fix round (commit follows this file).

## High

### 1. `buy(to = predicted pair)` unlocks the pool and captures the graduation ETH — CONFIRMED, FIXED
LaunchToken's seeding unlock keyed on `from == launchpad`, but a buy's payout has the launchpad as `from` and a
caller-chosen recipient. PoC measured: 1 ETH buy delivered 398.7M tokens into the predicted pair address and
unlocked it; attacker createPair + 1 wei WETH + mint became first LP; after graduation's second mint the
attacker could redeem **3.3298 ETH for 1 ETH spent** — the "all LP burned" guarantee false, launchpad solvency
intact (the loss lands inside the pair). Converges with CLAUDE-REVIEW-1 H1, which also confirmed the
poisoned-ratio escalation (migration mint revert → vault retries revert forever).
**Resolution:** double fix. `MintMarkLaunchpad._buy` rejects `to == pool` and `to == address(this)`
(`InvalidTo`); `LaunchToken._update` now unlocks only on a seeding PULL — `from == launchpad && msg.sender !=
launchpad` (the migrator's transferFrom) or `from == vault` — so a plain launchpad transfer can never unlock.
Regressions: Review1_Regressions `test_h1_*` (3) + invariant `invariant_noForbiddenBuyRecipients` with a
dedicated handler attack action.

## Medium

### 2. A prefunded graduation vault permanently dilutes dividends and can make `claimable` revert — CONFIRMED, FIXED
The vault address is CREATE2-predictable; `setVault` excluded it without adjusting the tracked eligible supply,
so a pre-parked balance became a phantom denominator share (PoC: 0.498 of 1 ETH distributed stuck forever), and
a balance that had already claimed made `claimable(vault)` underflow-revert.
**Resolution:** `setVault` accrues, then subtracts any pre-existing balance from the eligible supply exactly as
a boundary-crossing transfer would; `claimable`/`_claim` clamp to zero instead of underflowing. Regressions:
`test_m2_prefundedVaultNeitherDilutesNorReverts`, `test_m2_claimedBeforeExclusionDoesNotUnderflow` (which also
proves the vault retry still seeds the pool, parked tokens becoming locked liquidity).

## Low

### 3. The port dropped WETH, the router and the factory from the plugin denylist — CONFIRMED, FIXED
WETH as a plain fee destination converts creator fees into WETH owned by the launchpad (its receive() deposits
to msg.sender) — silently stranded; router/factory strand or block.
**Resolution:** `createToken` and the plugins' `_checkRecipient` now reject `migrator.weth()`,
`migrator.router()` and `migrator.dexFactory()` (IMigrator gained `dexFactory()`). Regressions:
`test_l3_wethRouterAndFactoryAreInvalidPlugins`, `test_l3_splitRefusesWethPayee`.

### 4. Registry listing squatting with a verifiable badge — CONFIRMED, FIXED
Front-running `list` locks the real author out forever; a curator badge could then stick to the squatter.
Converges with CLAUDE-REVIEW-1 M1.
**Resolution:** curator `delist()` frees a squatted or dead record for relisting (chosen over Grok's
`msg.sender == plugin` self-registration, which would bar EOA-authored listings of already-deployed
singletons); curation practice documented: verify only after confirming the expected author. Regression:
`test_m1_curatorDelistFreesASquattedAddress`.

## Notes — both FIXED or DOCUMENTED
- `authorFeeBps` uncapped → now rejected above 10_000 (`InvalidAuthorFeeBps`).
- `verified` not bound to bytecode → documented in the registry natspec: the curator should not verify
  upgradeable proxies, and re-reviews on change are policy, not code.

## Examined and considered sound (verbatim summary)
Curve ETH identity incl. a 64-run fuzz of quote-vs-execution and the exact-fill branch (no ethSpent > offered,
no solvency break); reentrancy on all ETH callbacks (nested buy/sell/collect all revert; nested claim pays 0);
graduation gas floor (cannot be starved into the vault) and the WETH-donation control (donor gets no LP);
plugin containment under push payment incl. Combo forwarding and Buyback's sell-out refund accounting; the
post-graduation buyback sandwich economics (flash-loan sandwich of a full cap unprofitable across 0.1x–20x
front-run sizes); dividend accounting apart from finding 2 (corrections, rounding, int256 bound unreachable,
forced ETH inert); registry fee custody (reentrant list cannot double-pay).
