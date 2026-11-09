# MintMark — adversarial security review #1

Scope: the ETH port of Architex v1.3 — the diff from the vendored baseline `bc8fadd` plus the wholly new files
(`MintMarkLaunchpad`, `LaunchToken`, `V2Migrator`, `GraduationVault`, the four plugins + base, `PluginRegistry`,
the deploy script). Reviewed against `docs/PLUGIN-MARKETPLACE-SPEC.md` and the documented solvency / liquidity-lock
invariants. Tooling: `forge build`, `forge test` (102 existing tests green), plus a confirmation suite
`contracts/test/Review1_PoC.t.sol` (5 tests, all green).

## Verdict

The money leg is in good shape: the ETH accrual/collection pattern, the sell-out refund, the gas-capped
graduation with vault fallback, and the dividend stream all hold up, and the project's own solvency and dividend
invariants pass. But the port introduced **one High-severity regression in the pre-graduation pool lock**: the
baseline rejected *every* transfer into the launch pair until graduation, whereas the port keys the unlock on the
*sender* being the launchpad — and the launchpad is also the sender of ordinary buy payouts. A buyer who passes the
predicted pool address as the `to` of a normal `buy()` therefore unlocks the pool and seeds it with curve tokens
while the curve is still live. This lets a third party become an LP holder *before* graduation, so graduation no
longer sets the opening price alone and the "LP burned / liquidity locked forever" guarantee is broken (confirmed
end-to-end: graduation still completes with no fallback vault, yet non-dead LP survives). This must be fixed before
deploy. Everything else I found is Medium and below: registry listing-squatting, a couple of griefing/stranding
edges, and the documented sandwich exposure on the post-graduation buyback.

---

## High

### H1 — Pre-graduation pool lock is released by an ordinary `buy()` whose `to` is the pool
**Severity:** High · **CONFIRMED** (`contracts/test/Review1_PoC.t.sol`: `test_f1_poolLockReleasedByBuyToPool`,
`test_f1_thirdPartyBecomesLpBeforeGraduation`, `test_f1_graduationSucceedsButLiquidityNotFullyBurned`)

**Location:** `contracts/launchpad/LaunchToken.sol:291-296` (the `_update` unlock condition) reached from
`contracts/launchpad/MintMarkLaunchpad.sol:369` (`IERC20(token).safeTransfer(to, tokensOut)` in `_buy`, with
`to` a caller-controlled parameter of `buy()` at `MintMarkLaunchpad.sol:276`).

**The regression.** The baseline `LaunchToken._update` reverted unconditionally on any deposit into the pair
before graduation:
```solidity
if (to == pair_ && pair_ != address(0) && !graduated) revert PairLockedUntilGraduation();
```
The port replaced this with a *sender*-gated unlock:
```solidity
if (to == pool_ && pool_ != address(0) && !poolUnlocked) {
    if (from != launchpad && (from != vault || from == address(0))) revert PoolLocked();
    poolUnlocked = true;
}
```
The intent is that only the migration (launchpad → pool) or the vault retry (vault → pool) may seed the pool. But
the launchpad is *also* the `from` of every normal buy payout (`safeTransfer(to, tokensOut)` runs
`_transfer(launchpad, to, …)`), and `buy()` lets the caller choose `to`. So `buy(token, 0, pool, deadline)` takes
the `from == launchpad` branch: it does **not** revert, it flips `poolUnlocked = true`, and it deposits the
buyer's curve tokens into the pool address — all while the curve is still live.

**Failure scenario (value capture / lock-lie, step by step):**
1. Token launches; `pool = poolFor(token)` is public and predictable; `poolUnlocked == false`.
2. Attacker calls `buy{value: x}(token, 0, pool, deadline)`. The payout transfer unlocks the pool and parks curve
   tokens at the (not-yet-created) pool address. `isGraduated(token)` is still false.
3. Attacker calls `factory.createPair(token, weth)` — it lands on the predicted address (CREATE2), already holding
   the tokens from step 2 — adds a WETH side, and calls `pair.mint(attacker)`, minting LP **to themselves**.
4. Later, the normal sell-out buy graduates the token. `V2Migrator.migrate` sees the pair already exists, transfers
   `POOL_SUPPLY` + the raise into it, and mints LP to `0xdEaD`. Because the pair already has reserves and an LP
   supply, the LP minted to dead is `min(...)` at the attacker's chosen ratio, and the attacker's pre-existing LP
   is untouched.
5. Result: graduation **succeeds** (no fallback vault — `vault() == address(0)`), but the attacker holds a
   material share of the graduated pool's LP, which they can withdraw. The opening price was influenced by the
   attacker's pre-seed rather than set solely by the curve.

The confirmation test `test_f1_graduationSucceedsButLiquidityNotFullyBurned` asserts exactly this post-state:
`isGraduated == true`, `vault == address(0)`, attacker LP balance `> 0`, and `dead LP < totalSupply`.

**Related impact (PLAUSIBLE, not separately PoC'd):** a pre-seed that drives the first-mint reserve ratio to an
extreme can make the graduation `mint()` round one side to zero and revert. That is caught by the `try/catch` and
parked in the `GraduationVault`, but every `vault.migrate()` retry hits the *same* poisoned pool and reverts
(the vault retry is not in a try/catch), so the 200M tokens + raise can be stranded in the vault permanently. The
sell-out buy itself still succeeds, so this is a liquidity brick, not a trading DoS.

**Why the invariant suite misses it:** `MintMarkInvariant`'s `SolvencyHandler` never calls `buy` with `to == pool`,
and the bug does not touch ETH solvency (`balance == pendingFees + Σ creatorFees + Σ floats` still holds — tokens
move, not ETH), so all 102 tests stay green.

**Suggested fix (do not apply):** restore the baseline's intent — do not let a buyer target the pool. Either
(a) in `buy()`/`_buy`, reject `to == c.pool` (and `to == address(this)`); and/or (b) replace the sender-based
unlock with an explicit, launchpad-driven signal: set a transient "graduating" flag in `_graduate`/`_parkInVault`
and have `_update` unlock only when that flag is set (or add a launchpad-only `markPoolUnlocked()` called inside
the migration path), so that `from == launchpad` on a *trade* payout never unlocks. Option (b) also covers any
future launchpad path that transfers to an arbitrary address.

---

## Medium

### M1 — PluginRegistry listing can be squatted; real authors are permanently locked out
**Severity:** Medium · **CONFIRMED** (`test_f7_registryListingSquatting`)

**Location:** `contracts/PluginRegistry.sol:62-84` (`list`). There is no check that `msg.sender` deployed or
controls `plugin`, and `list` is one-shot per address (`AlreadyListed`, `PluginRegistry.sol:67`), with no curator
override to reassign or remove a listing.

**Failure scenario:** anyone pays one listing fee and lists *any* address — including a plugin another team
deployed — recording themselves as `author` with an arbitrary `name` and `authorFeeBps` (the self-declared fee
disclosure the site renders). The genuine author can then never list their own plugin (reverts `AlreadyListed`
forever), and the squatter retains author-only control of the listing's mutable fields via `update`. The curator
can never make a squatted listing `verified` after review, so the *verified badge* is safe — but the browse/pick UI
renders unverified listings too, with the squatter's chosen name and understated fee, and the namespace is
permanently denied to the real author. Cost is bounded to one listing fee per squatted address; impact is bounded
to UI-level disclosure + denial (the registry gates nothing on-chain), which is why this is Medium not High.

The spec (§D5 / the contract NatDoc) explicitly accepts "a bad listing can mislead a reader until it is
unverified," so the *mislead* part may be intended — but the permanent lock-out of a real author and the
front-running of a listing are worth an explicit decision.

**Suggested fix (do not apply):** give the curator an admin path to clear/reassign a listing (e.g.
`curatorRemove(plugin)` that frees the slot), and/or require the lister to prove control of the plugin (e.g. a
plugin-declared `author()`/`owner()` the registry checks, when the address has code). At minimum, document that
listings are first-come and that only the verified badge is trustworthy.

---

## Low

### L1 — Renounced curator strands accrued registry listing fees
**Severity:** Low · PLAUSIBLE
**Location:** `contracts/PluginRegistry.sol:113-117` (`setCurator`, allows `address(0)` as an irreversible
renounce) and `:127-135` (`collectFees` reverts `ZeroAddress` when `curator == 0`).

If the curator renounces to `address(0)` while `pendingFees > 0`, those fees can never be collected
(`collectFees` reverts before it can send). The renounce is documented as intentional for freezing badges, but the
fee-stranding side effect is not. Fix: sweep `pendingFees` to the outgoing curator inside `setCurator`, or allow a
final `collectFees` before zeroing.

### L2 — Creator fees for a token whose hooked plugin reverts in `onFees` are permanently uncollectable
**Severity:** Low · PLAUSIBLE
**Location:** `contracts/launchpad/MintMarkLaunchpad.sol:168-182` (`collectCreatorFees`).
A plugin that declared `IMintMarkFeePlugin` at launch (so `pluginHooks == true`, stored and never re-probed) but
whose `onFees` always reverts makes `collectCreatorFees(token)` revert forever; that token's `pendingCreatorFees`
accrue with no way out. This is the creator's own plugin choice and ETH solvency is preserved (the fees stay
accrued and backed), so impact is confined to that one token's creator slice. Worth a one-line doc note; no code
change needed. Confirmed adjacent behavior in `test_f6_revertingPluginDoesNotBlockTrades` (trades/solvency
unaffected).

---

## Notes (observations, no action required or low-priority)

- **N1 — Post-graduation buyback swaps with `amountOutMin = 0`.** `BuybackBurnPlugin.run` →
  `swapExactETHForTokens(0, path, …)` (`contracts/plugins/launch/BuybackBurnPlugin.sol:112-114`) is sandwichable
  in principle. This is explicitly argued as acceptable in the NatDoc because the time-paced cap (≤0.25% of the
  ETH reserve per hour, one run per block) bounds per-run size; I agree the economic argument holds for the
  reference plugin, and flag it only so the trade-off is a conscious one.
- **N2 — Sell-out buy requires ~6M gas.** `_graduate` reverts `InsufficientGas` unless
  `gasleft() >= MIGRATION_GAS*64/63 + VAULT_GAS` ≈ 5.98M (`MintMarkLaunchpad.sol:393`). The 64/63 EIP-150 factor
  and the 900k vault reserve are arithmetically correct, and the floor correctly prevents a caller from starving
  the real migration (5M forwarded ≫ Pancake's ~2.5M create+mint, so the fallback can't be forced). The margin
  left for `_parkInVault` after a 5M-consuming migrate OOG is ~950k vs the 900k reserve — tight but adequate for
  the small vault deploy + token transfer. Worth re-measuring on Linea at deploy; no change needed.
- **N3 — `migrate` / `V2Migrator` front-running is contained *except via H1*.** A plain WETH-only donation to the
  predicted pool before graduation just joins the locked liquidity (dead gets the LP), as documented. Token-side
  pre-seeding is only possible through H1; fixing H1 closes the pool-manipulation surface here too.
- **N4 — Deploy script** (`contracts/script/DeployMintMark.s.sol`) wires `feeToSetter` as both launchpad fee admin
  and registry curator, and does not auto-list/verify the reference plugins (it logs a manual follow-up). Both are
  intentional per spec; just confirm the curator key is the intended one.

---

## Checked and found sound (so silence ≠ omission)

- **ETH solvency invariant** (`balance == pendingFees + Σ pendingCreatorFees + Σ floats`): holds across buy, sell,
  sell-out refund, graduation (both migrate-success and vault-fallback), and fee collection. The project's
  `MintMarkInvariant` solvency handler (≈14k calls/action, 0 reverts) and my reading of the accrual order agree.
  H1 moves tokens, not ETH, so it does not break this.
- **Fee accrual vs push:** trades (`buy`/`sell`) and `createToken` only ever *accrue* (`pendingFees`,
  `pendingCreatorFees`) and never call `feeTo` or a plugin, so neither can block a trade, launch, or graduation.
  `collectFees`/`collectCreatorFees` zero before they send and are `nonReentrant`; a revert restores the accrual.
  Confirmed.
- **Reentrancy on every new ETH path:** `buy` refund, `sell` payout, `collectFees`, `collectCreatorFees`,
  `LaunchToken.claim/_claim` (writes `claimed` before `sendValue`), `SplitPlugin.release` (writes `_released`
  first), `ComboPlugin.onFees` forwarding, `BuybackBurnPlugin.run` (incl. the launchpad refund arriving in
  `receive()` mid-run and the balance-delta spend accounting). All state-changing entrypoints are `nonReentrant`
  (launchpad and plugins) and effects precede interactions; the in-repo `ReentrantPlugin` harness and my reading
  both show reentry attempts revert with the guard. Sound.
- **Sell-out buy math:** `ethSpent <= offered` always (the cap in `_calcBuy`), refund goes to `msg.sender` after
  graduation, and the exact-fill fee split credits only ETH actually taken beyond `net`. No path lets `ethSpent`
  exceed the offer or redirect the refund. Sound.
- **`BuybackBurnPlugin` spend accounting:** `ethSpent = balanceBefore - balanceAfter` correctly nets the
  launchpad's mid-run refund; `held -= ethSpent` with `ethSpent <= offer <= held`; per-token ETH never crosses
  tokens; `receive()` restricted to the launchpad. Sound.
- **Dividend stream (`LaunchToken`):** uses `msg.value`/computed amounts, never `balance`, so `selfdestruct`-forced
  ETH is never credited; rounding always down (no over-credit); `uint128` eligible-supply casts stay within range
  (≤1e27 total supply); pause below `MIN_ELIGIBLE_SUPPLY` moves the end out without backlog; corrections keep
  earned dividends fixed across transfers/burns/pulls. The project's dividend invariant passes and my reading
  agrees. The exclusion set grows (vault) only while the member's balance is zero (`setVault` precedes the token
  transfer in `_parkInVault`), so eligible-supply tracking is consistent — **except** that H1 makes `poolUnlocked`
  flip early; the pool is excluded regardless of unlock, so dividend accounting itself stays correct even under H1.
- **ERC-165 plugin containment:** lying (`0xffffffff`-true), gas-guzzling, and hookless contracts are all treated
  as plain addresses (ERC165Checker 30k cap; decision stored once at launch, never re-probed), so a plugin cannot
  switch between hook-paid and transfer-paid, and cannot extract more than its accrued slice. Combo nesting is
  bounded (≤5 entries, `_checkRecipient` rejects launch tokens and self) and a reverting nested plugin only blocks
  its own token's collection. Sound.
- **Graduation gas floor arithmetic:** see N2 — correct, cannot be gamed to force the fallback.
- **`V2Migrator` constructor probe:** proves `pairCodeHash` against `allPairs(0)`, so a wrong hash can't be
  configured; `poolFor` matches `getPair`/`createPair` on the real Pancake factory (fork test passes the full
  lifecycle). Sound.

## Files added
- `contracts/test/Review1_PoC.t.sol` — 5 confirmation tests (all pass against the current, vulnerable code). Note:
  the H1 tests assert the *current* behavior, so once H1 is fixed they will fail at `buy(to = pool)` (which will
  then revert `PoolLocked`) — invert or delete them as part of the fix. No source contracts were modified.

---

## Resolutions (fix round, 2026-10-06)

- **H1 — FIXED**, by both suggested layers: `_buy` rejects `to == pool` / `to == address(this)` (new
  `InvalidTo`), and the token's unlock now requires a seeding PULL (`from == launchpad && msg.sender !=
  launchpad`, or `from == vault`), so no plain launchpad transfer can ever unlock. The PoC file asserting the
  vulnerable behaviour was replaced by `contracts/test/Review1_Regressions.t.sol` (inverted assertions), and
  the solvency invariant suite gained a dedicated `curveBuyToForbiddenRecipient` attack action plus
  `invariant_noForbiddenBuyRecipients`. GROK-REVIEW-1 found the same hole independently and quantified the
  theft (3.33 ETH captured per 1 ETH spent); its poisoned-ratio escalation is closed by the same fix (tokens
  can no longer reach the pool pre-graduation at all).
- **M1 — FIXED** with the curator-removal option: `PluginRegistry.delist()` frees a squatted record for
  relisting; `authorFeeBps` capped at 10_000. Regressions in Review1_Regressions.
- **L1 — FIXED**: renouncing the curator now requires pending listing fees to be collected first
  (`FeesPending`), so nothing strands.
- **L2 — ACCEPTED** as designed: a token whose hooked plugin always reverts strands only its own creator fees,
  which is the launcher's own plugin choice; solvency unaffected. Documented in `collectCreatorFees` natspec.
- **N1/N2/N3/N4 — ACCEPTED** as documented trade-offs; N2's gas floor re-measure stays on the Linea Sepolia
  rehearsal checklist.

Full suite after fixes: 111 passed, 0 failed (plus 2 Linea-fork tests, both green against the real Pancake
factory). Slither re-run clean of new findings.
