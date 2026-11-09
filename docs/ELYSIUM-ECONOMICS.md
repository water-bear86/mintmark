# Elysium economics review

Reviewed 2026-11-08. Source-code baseline, not deployed-chain state or an economic recommendation. The user approved a 30 HYPE net graduation target. Native virtual reserve and matching demo curve were updated; supply, fee rates/caps and deployment fee defaults were not changed. No deployment or funded transaction was performed. All native amounts are HYPE, with 18 decimals; Solidity `ether` literals and legacy `ETH` names mean units of the chain's native asset, not an ETH exchange-rate conversion.

## Supply and virtual reserves

Source: `contracts/launchpad/MintMarkLaunchpad.sol` constants and core math.

- Total: 1,000,000,000 tokens (18 decimals).
- Bonding curve allocation: 800,000,000 tokens (80%).
- DEX liquidity allocation: 200,000,000 tokens (20%). No separate free creator allocation.
- Initial virtual tokens: 1,066,666,667 tokens.
- Initial virtual native reserve: 10,000,000,012,500,000,000 wei = 10.0000000125 HYPE. This is virtual, not a deposit requirement.
- Final virtual token reserve: 266,666,667 tokens.
- Graduation is triggered by selling all 800M curve tokens, not by a separately configurable native threshold.

## Exact fresh-curve baseline

Assumption: one sell-out buy from a fresh curve; no earlier trades, no unsolicited pool donations. Let E and T be initial virtual reserves in base units, C curve token units, and ceil integer ceiling division. Final native reserve = ceil(E*T/(T-C)); net liquidity = final native reserve - E. Calibrate E = 30e18 * (T-C) / C = 10,000,000,012,500,000,000 wei exactly. This calibration reaches the exact fresh baseline target while retaining token reserves and relative curve shape; it is not a flat multiple of the old rounded reserve.

| Quantity | Exact HYPE amount |
| --- | ---: |
| Final virtual native reserve | 40.000000012500000000 |
| Net HYPE raised and sent for liquidity | 30.000000000000000000 |
| Opening contract marketCap() | 7.500000007031249997 |
| Final contract marketCap() | 119.999999887500000140 |
| Opening full-supply FDV, floored to wei | 9.375000008789062497 |
| Final full-supply curve FDV, floored to wei | 149.999999859375000175 |
| Initial DEX FDV, absent prior native donations | 130.000000000000000000 |

`marketCap()` deliberately multiplies the virtual reserve ratio by **800M**, not total 1B supply. Full-supply FDV is 1.25 times the corresponding unrounded metric. Neither is cash raised. The curve's initial spot is approximately 0.0000000078130 HYPE per token; final spot approximately 0.000000130 HYPE per token. `spotPrice()` returns wei per whole token scaled by another 1e18, so divide its integer result by 1e36 to display HYPE/token.

The DEX pairs net native liquidity with 200M tokens. Its opening price is extremely close to, but not exactly, the final curve price because the constants use rounded virtual token reserves. Prior wrapped-native donations can also change the opening DEX ratio. Migrator LP tokens go to the dead address. If migration fails, the assets park in an ownerless retryable vault; graduation alone therefore does not prove a pool was created.

**Path dependence:** k is recomputed after every trade, with rounding favoring the curve. Multi-trade histories can change the exact final wei amount. The table is an exact reproducible baseline, not a universal fixed final balance. Multi-trade rounding is explicitly covered by Solidity regression tests. On a live curve use `quoteBuy` and current reserves. Sell/buy churn also adds fees, so cumulative gross volume is not a fixed graduation requirement.

### Gross sell-out cost, excluding launch fee and gas

| Creator fee | Combined nominal trade fee | Exact HYPE spent | Platform portion | Creator portion |
| --- | ---: | ---: | ---: | ---: |
| 0% (default until selected) | 0.5% | 30.150753768844221106 | 0.150753768844221106 | 0 |
| 0.5% (optional creator setting) | 1% | 30.303030303030303031 | 0.151515151515151516 | 0.151515151515151515 |
| 10% (contract maximum) | 10.5% | 33.519553072625698325 | 0.167597765363128492 | 3.351955307262569833 |

Exact-fill net N, combined fee bps f: spent = N + ceil(N*f/(10000-f)); platform = ceil((spent-N)*50/f); creator = spent-N-platform. Normal buys initially compute platform and creator ceilings independently. Offering exactly the displayed gross can miss the exact-fill branch by dust; an over-offer with appropriate output guard is refunded, and the table reports actual spent, not a guaranteed minimum offer. The offline check uses 2 wei headroom. Normal buys and sells charge both fee components rounded up, so effective rates on tiny trades can exceed nominal rates.

## Fees and deployment defaults

Sources: `MintMarkLaunchpad.sol`, `PluginRegistry.sol`, `contracts/script/DeployMintMark.s.sol`, `config/elysium*.env.example`, and `src/app/LiveApp.tsx`.

- Platform trading fee: fixed 50 bps (0.5%) of gross on buys and sells. No owner setter.
- Creator trading fee: chosen per token at launch, 0–1,000 bps (0–10%), then fixed. The live UI defaults to 0 bps and the connected account as recipient, with creator-selected rate controls; the basic launch flow fixes the recipient to that reviewed connected wallet. A contract caller may select a supported plugin or other valid recipient.
- Launch fee: constructor/deployment input, mutable by feeToSetter, maximum 10,000,000,000,000,000 wei (0.01 HYPE). There is **no selected deployment default**: the env examples leave LAUNCH_FEE_WEI blank and deployment requires it. Token creation accepts maxLaunchFee protection; any payment above the fee becomes an initial buy.
- Plugin marketplace listing fee: constructor input, mutable by curator, maximum 50,000,000,000,000,000 wei (0.05 HYPE). LISTING_FEE_WEI is also blank/required, not implicitly zero. Listing requires exactly the fee; it is not a fee on every token launch. Plugins do not need registry listing to work.
- Listing authorFeeBps: disclosure only, 0–10,000 bps of routed fees; it does not itself enforce or charge an additional trading fee.
- Platform fees accrue to FEE_TO; creator fees accrue to each token's destination and can be collected **before graduation**. There is no enforced graduation escrow or general native burn split.
- Registry listing fees accrue to the curator, initially FEE_TO_SETTER in this deployment script. These are distinct from platform fee revenue. Fees are separate from liquidity reserves.
- Network gas and post-graduation DEX trading fees are separate. This review does not establish the configured DEX's trading fee or current gas costs.

## Browser demo discrepancies

`src/timeline.ts` now uses the same virtual reserve scale and token counts as the contracts, so its floating-point illustration targets approximately **30 HYPE** net liquidity. It remains a simulation and does not reproduce wei-level, history-dependent integer rounding. Previously the separate demo curve showed approximately 4.396 HYPE; that discrepancy is removed.

The demo is aligned to the same fixed 0.5% platform fee plus selected 0–10% creator fee, with explicit simulated claims before or after graduation. Its sealed-order window remains a browser-only demonstration, not onchain privacy. Native token burn and graduation escrow are not contract guarantees. Contract progressBps uses token units sold/800M; demo progress uses net raised/graduation raise.

At review time, market.ts contained a sample HYPE_USD = 2500 while the demo footer claimed a fictional $1/HYPE rate. The footer now reads the same HYPE_USD constant so the label matches the calculation; the rate remains fictional and is not a current quote. This report makes no USD valuation. The landing sample launches are separately generated fictional market data.

## Owner decisions before funded deployment

1. The user has selected 30 HYPE net graduation liquidity; 80/20 allocation and token-reserve curve shape are preserved. Fee settings and recipient/admin choices below remain open. Changing native denomination does not preserve an ETH-denominated dollar value.
2. Set actual launch fee (0–0.01 HYPE) and plugin listing fee (0–0.05 HYPE). Zero is possible but has not been selected.
3. Supply and verify FEE_TO and FEE_TO_SETTER, recognizing that the latter initially receives registry fees and controls curation and mutable fees.
4. Creator fee controls expose the existing 0–10% range in 0.01% steps, defaulting to zero until chosen. Rate and recipient are fixed at launch. Collection pays the recorded recipient, never whoever presses the button. Arbitrary post-launch fee increases, escrow or automatic native burning are not enabled.
5. Displayed contract market cap remains the 800M metric; demo FDV uses1B. USD conversion is still explicitly fictional. Neither is the liquidity target.

Deployment additionally needs verified chain/DEX configuration, funded signer approval and security review. Those are not satisfied by these calculations.

## Reproduce offline

Run `node scripts/check-economics.mjs` from the repository root. It reads current Solidity constants, uses BigInt ceiling/floor arithmetic, checks supply and baseline net liquidity, and prints exact reserve, cap and fee values. It does not connect to RPC, sign, or transmit transactions. Its baseline assertion intentionally fails if curve constants change, requiring this document to be reviewed again.


## Historical Linea comparison

The original repository code at commit `27e1998` had virtual native reserve 1.666666666666666667 ETH and a fresh-curve net graduation raise of 4.999999993750000009 ETH (~5 ETH). The 6.666666660416666676 ETH final virtual reserve included the initial virtual reserve and was not cash held. The original browser demo separately used a ~4.396 ETH curve and a fictional $2,500/ETH display conversion; 5 ETH at that illustrative rate would be $12,500. No deployment/broadcast record was found, so this is the implemented Linea design, not a claim about deployed mainnet state. The newly approved 30 HYPE scale is not an ETH/USD-equivalent conversion.


## Creator collection semantics

The contract already implements `collectCreatorFees(token)` with reentrancy protection, accrued-balance clearing before the external call, and revert restoration. Any caller may trigger collection, but the fixed stored destination receives the payout. For a direct wallet recipient this pays native HYPE to that wallet; for a fee plugin it invokes the plugin hook and is not necessarily an individual withdrawal. Creator fees apply to bonding-curve buys/sells, not ordinary post-graduation V2 trades. This change exposes the existing mechanism instead of inventing a second custody/withdrawal system. No fee cap or post-launch mutability is expanded.
