# MintMark

Token launchpad targeting Kinetiq Elysium (native HYPE). Preserves the 3D landing page and explicit demo. See [Elysium migration and deployment gates](docs/ELYSIUM-MIGRATION.md) before configuring live mode or deploying.

## Run

```bash
npm install
npm run dev      # http://localhost:5190
npm run build
```

Add `?snap` to the URL in dev to skip camera easing (handy for screenshots).

## How the lander works

- `src/timeline.ts` is the single source of truth: scroll `beat` (0 hero, 1 cast, 2 curve, 3 graduate, 4 live, 5 fees, 6 cta), the bonding curve math, and world layout. It has no three.js import so the page shell stays small.
- `src/App.tsx` is the HTML: Lenis smooth scroll maps section offsets to `beat` and drives the live curve readout.
- `src/scene/*` is the lazy-loaded React Three Fiber scene. Every object reads `scroll.beat` in `useFrame`; `Rig.tsx` holds the camera shot list.
- Mobile / coarse pointers get a lighter scene without postprocessing. `prefers-reduced-motion` freezes the scene on the hero shot.

## Status

- Launch data on the page is sample data (`src/launches.ts`).
- Fee, curve and graduation numbers are proposed parameters, not final.

## Elysium backend

- `npm test`: exact amount and mocked RPC/wallet client regressions (Node 24+).
- `npm run test:contracts`: local Solidity tests and invariants; fork tests skip unless explicitly configured.
- `config/elysium.env.example`: testnet config; `config/elysium-mainnet.env.example`: independently checked community mainnet RPC/V2 config.
- `node scripts/verify-elysium-rpc.mjs`: read-only pinned-state comparison and pair CREATE2 proofs; saved evidence in `docs/elysium-verification.json`.
- Live contract access requires `VITE_ELYSIUM_LAUNCHPAD_ADDRESS` for an independently verified deployment, with matching network/RPC settings. A configured address is not automatically a trusted deployment.
- [Migration guide](docs/ELYSIUM-MIGRATION.md) records successful mainnet V2 local-fork lifecycle tests, remaining deployment/production gates, preserved HYPE-denominated economics, and preflight/verification steps. No deployment has been performed.

### Live UI scope

`/app` remains the explicit simulation; `/app/live` is the separate wallet-backed mode and stays unavailable until a verified deployment is configured. The basic live view offers paginated curves, quoted buys/sells (1% slippage, quotes expire after 60 seconds, transaction deadline 120 seconds), and fixed-1B-supply launches. Basic creation has no initial buy; creator fee controls expose the existing 0–10% range; the launch recipient is the reviewed connected wallet, with explicit fee collection to the saved recipient. It accepts an existing metadata URI, not a file upload. Graduated tokens use the launchpad’s verified migration route for native HYPE buys/sells, with a separate exact-amount approval for DEX sells. Failed/unfunded migrations stay blocked. It does not yet provide charts/indexing or private batch auctions. Unknown send/receipt outcomes persist a localStorage gate and require wallet reconciliation rather than automatic retry. Cancellation/replacement is not reported as a successful trade.

Recovery records contain only public transaction intent and hashes, scoped by chain and launchpad. They survive closing and reopening a tab. Existing sessionStorage recovery records migrate without overwriting conflicting durable records. Before sending, a pre-existing intent or pending hash blocks the new request. This is a fail-closed cross-tab check, not an atomic cross-tab lock.

HYPE economic decisions and reproducible integer calculations are in [Elysium economics](docs/ELYSIUM-ECONOMICS.md); run `node scripts/check-economics.mjs`. The user-approved fresh-curve target is 30 HYPE net liquidity; supply allocation and fee rates/caps are unchanged.
