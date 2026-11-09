# MintMark on Kinetiq Elysium

Network port, November 8, 2026. This targets **Kinetiq's Arbitrum Orbit L2** (native HYPE), not the unrelated Elysium/ELY chain 1339.

## Verified configuration

Official sources:
- https://elysium.kinetiq.xyz/docs/connecting-to-elysium (updated November 7): testnet 99801, mainnet 99901. Testnet public RPC `https://testnet-rpc.elysium.kinetiq.xyz`. Official public mainnet RPC and explorer were not published in the initial source. Community mainnet RPCs have now been verified below. Alchemy’s current FAQ supports testnet only; do not assume an Alchemy mainnet endpoint is available.
- https://elysium.kinetiq.xyz/docs/building-on-elysium: standard Solidity/Foundry support; native HYPE. HyperCore read/write features are post-launch, not a dependency of this port.
- https://elysium.kinetiq.xyz/docs/contract-addresses: testnet WHYPE `0xCD57F65c2B0e5881CFC2E609F7CD53b746E1F234`. Official mainnet contract listing was pending. Independent mainnet evidence and live read-only verification are recorded below.

## Scope and compatibility

Solidity's `msg.value` and `ether` unit are chain-native, so existing accounting, plugin, dividend, recovery and graduation logic operates in HYPE on Elysium. Existing ETH-named ABI fields and methods remain unchanged to avoid breaking plugins or consumers. Curve supply and fee caps are unchanged. The user subsequently approved 30 HYPE net graduation liquidity; native virtual reserve is calibrated to 10.0000000125 HYPE while token reserves and relative curve shape stay unchanged. This is not a promise of equivalent ETH-dollar economics. See ELYSIUM-ECONOMICS.md for rounding and remaining fee/admin decisions.

`src/network/client.ts` is a real wallet-backed contract client for reads, quotes, launch, buy, sell and receipts. It uses compiler-generated ABI, checks RPC and wallet chain IDs, rejects missing contract bytecode, simulates writes before the wallet prompt, and rechecks the account before sending. Amounts are integer wei; `amounts.ts` rejects rounding and excess precision. A bytecode presence check is not proof of contract identity: configure only an owner-verified deployment address and verify its source/runtime before use. No private keys or server signing. Sells require no ERC-20 allowance: the launchpad-only token `pull` moves only the seller's tokens. Metadata URIs are supplied by the caller; there is no unrequested upload or storage service.

## Deployment blockers (not optional)

Mainnet V2 compatibility is now verified against two community RPC operators using existing pair CREATE2 proofs and full local-fork lifecycle tests (see below). This is not a Kinetiq/Uniswap endorsement or security audit. A gateway router in Elysium’s bridge docs is **not a DEX router**. Reverify state at public launch: prelaunch reset is possible. MintMark itself still requires owner-approved fee settings, deployment, source/runtime verification and real-wallet validation. No MintMark deployment record exists in this repository. The factory must already have a pair so its CREATE2 hash can be proven. An empty new factory deliberately fails preflight.

No contracts were deployed, wallets connected, transactions broadcast, or funds used. A successful local build is not evidence of live-network readiness. The demo remains explicitly simulated. On-chain private/sealed auctions were never implemented by the original contracts; the demo's sealed auction must not be marketed as live privacy.

## Configuration

Copy `config/elysium.env.example` to a local ignored environment file, fill verified deployment values, and load it into your shell. Never place private keys or provider secrets in VITE variables: they are public browser configuration. Use a restricted public browser endpoint or a separately operated RPC proxy for production. A mainnet selection without an endpoint is deliberately unavailable rather than silently using testnet.

Before deployment run:

    npm run build
    node scripts/test-network.mjs
    forge test
    ELYSIUM_FORK_RPC_URL="$ELYSIUM_RPC_URL" forge test --match-contract ElysiumForkTest
    forge script contracts/script/DeployMintMark.s.sol:DeployMintMark --rpc-url "$ELYSIUM_RPC_URL"

The last command is a simulation only: do not add `--broadcast` until the owner authorizes deployment. The script checks chain, bytecode, WHYPE, factory and pair hash before starting broadcasts. Configure `VITE_ELYSIUM_LAUNCHPAD_ADDRESS` only after deployment verification. The original Linea fork test is retained solely as historical regression coverage and is skipped unless its old explicit environment variable is supplied.

After deployment: verify contract source, register/verify fee plugins using the curator, check bytecode and event indexing, test wallet account/network changes, and test launch/trade/graduation/recovery end-to-end on the selected Elysium network. Do not advertise audited contracts: no new audit was performed.

## ArbOS block semantics

Buyback pacing now uses `ArbSys.arbBlockNumber()` at `0x64` on Elysium (99801/99901), because Solidity `block.number` tracks the parent-chain block under ArbOS. This preserves one-run-per-local-block behavior rather than unintentionally throttling to HyperEVM blocks. A missing/malformed precompile fails closed on Elysium; historical non-Elysium tests retain `block.number`. Timestamp-based deadlines remain timestamp-based. Fixed migration/fallback gas budgets are preserved. Graduation succeeded against the current mainnet V2 deployment in local fork tests; this does not establish a worst-case production gas bound.

Wallet submission errors are conservative: only explicit user rejection proves a send was not authorized; a timeout/disconnect after requesting submission is treated as uncertain and must be reconciled before another send. Receipt cancellation/replacement does not confirm the original action. A repriced receipt is accepted only when recipient, calldata and value still match the original request.

Submission reconciliation records chain, sender, destination, calldata, value and an explicit pending nonce in localStorage before asking the wallet to send. Storage failure aborts the request. A returned hash is persisted before the intent is cleared. After reload, an unknown-send hash must match every recorded field, including the nonce: an older identical call cannot unlock it. Legacy or malformed account-only records stay locked and cannot be reconciled by supplying an arbitrary hash. Known-hash cancellation/replacement remains a terminal non-success outcome. Unknown-hash transactions with different calldata (including a cancellation) are not accepted as the requested action; inspect wallet activity manually rather than retrying blindly.

Recovery records contain only public transaction intent and hashes, scoped by chain and launchpad. They survive closing and reopening a tab. Existing sessionStorage recovery records migrate without overwriting conflicting durable records. Before sending, a pre-existing intent or pending hash blocks the new request. This is a fail-closed cross-tab check, not an atomic cross-tab lock.


## Mainnet investigation and read-only verification (November 8, 2026)

Do not conflate official deployment endorsement with independently checked compatibility. Uniswap’s official deployment list currently omits Elysium. [Titan Locker](https://titanlocker.com/docs/uniswap-on-elysium) publishes candidate V2 addresses. [0xProject’s own chain configuration](https://github.com/0xProject/0x-settler/blob/master/chain_config.json) independently identifies chain 99901 and the same wrapped-native address. App-operator documentation also agrees on WHYPE.

- Mainnet chain: `99901`, HYPE (18 decimals).
- Community RPCs: `https://node.eleos.fun` ([Opsis API documentation](https://elysiumexplore.com/api-docs)) and `https://rpc.hips.family` ([operator documentation](https://hips.family/docs)). Both returned the correct chain and matching router/WHYPE/factory relationships. Opsis warns prelaunch state may reset; these are not Kinetiq-operated endpoints.
- WHYPE: `0xbA876237B0F021A6c6D852d6c26E107997cC5E81` (runtime code present).
- V2 Router02: `0xe783de89a7f0408687f051e3e6d0beb62719ebad`.
- Factory returned by that router: `0xbbbcc62853a5fa27b93d6bab3e6f7ce841e25df2`.
- Pair init-code hash: `0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f`, from [Uniswap’s own V2 library](https://raw.githubusercontent.com/Uniswap/v2-periphery/master/contracts/libraries/UniswapV2Library.sol), then **proven against an existing factory pair**, not accepted on the basis of the name alone.
- Existing pair used by preflight: `0x10f964b6A82f9442bB20994551fdD5193346154a`; factory reported two pairs.

Both `ElysiumForkTest` tests passed against Opsis state at block 2,220,982 and hips.family state at block 2,221,042. These tests execute entirely locally: launch, buy, sell, graduation through the deployed router/WHYPE into a V2 pair, LP burn and fee collection. The bad pair-hash check also passed. No transaction was broadcast and no funds were spent. This closes the V2 compatibility blocker for the observed state, not the deployment/audit/production-validation blockers.

The public testnet RPC was also read directly: chain `99801`, advancing block and 2,202-byte code at the documented testnet WHYPE address. No verified testnet V2 deployment was assumed.

`config/elysium-mainnet.env.example` contains the tested community network/DEX configuration with MintMark’s address intentionally blank. Copy and load it only when explicitly choosing this provider; do not activate a guessed launchpad address. Mainnet Alchemy support is **not** assumed: [its current FAQ](https://www.alchemy.com/docs/reference/elysium-api-faq) lists testnet only. Re-run verification and fork tests after public launch or any reset before deployment.

Reproduce the saved pinned-state evidence with `node scripts/verify-elysium-rpc.mjs`; the report is `docs/elysium-verification.json`. Set `ELYSIUM_FORK_BLOCK=2220982` with the mainnet template variables to rerun the fork tests at the same block. The recorded block hash is `0x0cf7a02b5b8c6faf715ba10b75fbe707f3e3ef85b859bb550b43f39e57b83440`. The two community endpoints agree; this does not establish that their infrastructure is independent or replace source verification.

Additional provenance and provider checks:
- Factory and both pair runtime bytecodes exactly match the published `@uniswap/v2-core@1.0.1` artifacts. Pair creation bytecode hashes to the proven CREATE2 hash. Router runtime has not been compared to its canonical artifact; interface/fork compatibility is not a router audit.
- WHYPE has nonzero EIP-1967 implementation (`0xf098387f303B6bBfE9dA7CB16F70639b76430542`) and admin (`0xDeae688C60778379F98f3E29c7e94d6e3934a30A`) slots, each with deployed code. Do not describe it as immutable; upgrade-control ownership and policy remain unverified.
- Both chosen providers return transaction receipts, transaction-by-hash and pending nonce. A known factory deployment receipt succeeded and its created address matches the factory. Narrow `eth_getLogs` queries succeed, but **both actually enforce at most 2,000 blocks per request**, despite Opsis documentation mentioning 10,000. Any future event indexer must paginate at 2,000 or less. The present live UI reads `curvesPage` directly and does not rely on a pending feed or log indexer. These checks do not establish provider availability/SLA or the ability to broadcast before public launch.


## Post-graduation trading

The live client now derives V2 router, factory, wrapped native and pool from the configured launchpad's migrator. It verifies contract code, the token's launchpad/pool/unlocked state, matching pair tokens/factory/mappings and nonzero reserves. A curve marked graduated without usable liquidity remains blocked. Native HYPE buys and token-to-HYPE sells use protected V2 router swaps; selling requires a separate exact-amount allowance transaction and a fresh quote afterward. Approval and swap intents persist their actual token/router target for nonce-bound recovery. No unlimited approval or automatic swap after approval is used.

Five pinned Elysium fork tests pass, covering lifecycle/CREATE2 plus post-graduation buy/sell, exact approval consumption, missing approval rejection, slippage rollback and deadlines. Mock client regressions cover route mismatches, simulation failures, wrong chains and uncertain approvals/swaps. These are local tests, not live wallet or funded mainnet testing. Quote expiry is 60 seconds with a 1% protected minimum; transaction deadline is 120 seconds.


## Approved 30 HYPE scale

The user approved a 30 HYPE net liquidity target. Fresh single-fill graduation now seeds exactly 30 HYPE before any external pool donations; multi-trade integer rounding can vary the final wei amount slightly. Gross spend at zero creator fee is 30.150753768844221106 HYPE, excluding launch fee/gas. Demo virtual reserves and displays match the new scale. Earlier pinned fork success above used the prior ~5 HYPE scale; new-scale fork fixture amounts are updated but a repeat request to the external RPC was blocked by the execution network policy. Offline regression tests do not replace this outstanding new-scale fork rerun.


## Creator fee controls and collection

Launch now offers 0–10% creator fees in 0.01% increments, defaulting to zero. The connected wallet is the reviewed fee recipient. Both rate and recipient are immutable after launch; the fixed platform fee remains 0.5%. The new Fees tab accepts a token address, reads pending fees and destination from the configured launchpad, and uses the existing `collectCreatorFees(token)` transaction to collect only to that destination. Anyone can pay gas to trigger collection, but cannot redirect another creator’s fees. A plugin destination is a collection into that plugin, not necessarily a wallet withdrawal.

Collection is available before or after graduation for already accrued bonding-curve fees. Ordinary V2 swaps after graduation do not generate creator fees. Existing nonReentrant/zero-before-send protections and revert restoration remain unchanged; added tests exercise recipient isolation, repeat claims, reverting recipients, accounting and reentrancy. UI writes retain exact signer binding and durable nonce-bound recovery.

The demo offers corresponding simulated fee selection and a creator-only demo claim action, clearly marked as no real money. It no longer models mandatory graduation escrow or an automatic native burn split. The sealed window remains explicitly a browser-only demonstration. No onchain fee cap has been raised and no post-launch fee setter was added.
