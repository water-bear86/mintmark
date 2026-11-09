import { useSyncExternalStore } from "react";
import { CURVE_SUPPLY, TOTAL_SUPPLY, V_ETH0, V_TOK0, GRAD_RAISE } from "../timeline";
import { LAUNCHES } from "../launches";

// ─────────────────────────────────────────────────────────────────────────────
// Simulated market. Every number comes from the same virtual-reserve bonding curve
// the lander illustrates; only the traders are fake. Resets on reload.
// No curve balances/history are persisted, so parameter changes need no storage
// migration. Preserve the independent watchlist and live transaction recovery.
// ─────────────────────────────────────────────────────────────────────────────

export const PLATFORM_FEE_BPS = 50;
export const MAX_CREATOR_FEE_BPS = 1000;
export const feeRate = (t: Pick<Token, "creatorFeeBps">) => (PLATFORM_FEE_BPS + t.creatorFeeBps) / 10_000;
export const SEALED_MS = 60_000;
export const HYPE_USD = 2500; // sample rate for display only
const K = V_ETH0 * V_TOK0;
// Scale only fictional crowd orders to retain the sample graduation pacing.
const CROWD_TRADE_SCALE = GRAD_RAISE / (1.5 * 800_000_000 / 273_000_000);

export type Trade = { t: number; side: "buy" | "sell"; eth: number; tokens: number; price: number; wallet: string; sealed?: boolean };
export type SealedOrder = { wallet: string; eth: number };
export type Token = {
  id: string;
  name: string;
  ticker: string;
  desc: string;
  image: string | null;
  creator: string;
  createdAt: number;
  sold: number;
  graduated: boolean;
  graduatedAt?: number;
  sealedUntil: number;
  sealed: SealedOrder[];
  trades: Trade[];
  holders: Record<string, number>;
  readonly creatorFeeBps: number;
  readonly creatorRecipient: string;
  creatorAccrued: number;
  creatorClaimed: number;
  platformFees: number;
  links: { x?: string; site?: string };
};

// ── Curve maths ─────────────────────────────────────────────────────────────
const vTok = (sold: number) => V_TOK0 - sold;
export const priceAt = (sold: number) => K / vTok(sold) ** 2; // HYPE per token
export const raisedAt = (sold: number) => K / vTok(sold) - V_ETH0;
export const progressOf = (t: Token) => Math.min(raisedAt(t.sold) / GRAD_RAISE, 1);

export function quoteBuy(t: Token, ethIn: number) {
  const rate = feeRate(t);
  ethIn = Number.isFinite(ethIn) ? Math.max(0, ethIn) : 0;
  let net = ethIn * (1 - rate);
  const vE = K / vTok(t.sold);
  let tokens = vTok(t.sold) - K / (vE + net);
  const room = CURVE_SUPPLY - t.sold;
  let capped = false;
  if (tokens > room) {
    // Only the HYPE needed to finish the curve is used.
    capped = true;
    tokens = room;
    net = K / vTok(t.sold + room) - vE;
  }
  const spot = priceAt(t.sold);
  const avg = tokens > 0 ? net / tokens : spot;
  const ethUsed = capped ? net / (1 - rate) : ethIn;
  return { tokens, fee: ethUsed * rate, creatorFee: ethUsed * t.creatorFeeBps / 10_000, platformFee: ethUsed * PLATFORM_FEE_BPS / 10_000, avg, impact: avg / spot - 1, capped, ethUsed };
}

export function quoteSell(t: Token, tokensIn: number) {
  const vE = K / vTok(t.sold);
  const tokens = Math.min(Number.isFinite(tokensIn) ? Math.max(0, tokensIn) : 0, t.sold);
  const gross = vE - K / (vTok(t.sold) + tokens);
  const fee = gross * feeRate(t);
  const spot = priceAt(t.sold);
  return { eth: gross - fee, fee, creatorFee: gross * t.creatorFeeBps / 10_000, platformFee: gross * PLATFORM_FEE_BPS / 10_000, avg: tokens > 0 ? gross / tokens : spot, impact: 1 - (tokens > 0 ? gross / tokens : spot) / spot };
}

// ── Derived stats ───────────────────────────────────────────────────────────
const HOUR = 3_600_000;
export function stats(t: Token, now = Date.now()) {
  const price = priceAt(t.sold);
  let inflow = 0;
  let volume = 0;
  let priceHourAgo = priceAt(0);
  for (const tr of t.trades) {
    if (tr.t >= now - HOUR) {
      inflow += tr.side === "buy" ? tr.eth : -tr.eth;
      volume += tr.eth;
    } else priceHourAgo = tr.price;
  }
  const holders = Object.values(t.holders).filter((v) => v > 1).length;
  return {
    price,
    mcapEth: price * TOTAL_SUPPLY,
    mcapUsd: price * TOTAL_SUPPLY * HYPE_USD,
    progress: progressOf(t),
    raised: raisedAt(t.sold),
    inflow1h: inflow,
    volume1h: volume,
    change1h: priceHourAgo > 0 ? price / priceHourAgo - 1 : 0,
    holders,
    sealedLive: now < t.sealedUntil,
    ageMs: now - t.createdAt,
  };
}
export type Stats = ReturnType<typeof stats>;

// ── Randomness + wallets ────────────────────────────────────────────────────
let rngState = 20260927;
const rnd = () => ((rngState = (rngState * 1664525 + 1013904223) % 4294967296) / 4294967296);
const hex = (n: number) => Array.from({ length: n }, () => Math.floor(rnd() * 16).toString(16)).join("");
const newWallet = () => "0x" + hex(40);
const CROWD = Array.from({ length: 360 }, newWallet);
const someone = () => CROWD[Math.floor(rnd() * CROWD.length)];
const lognormal = (mu: number, sigma: number) => Math.exp(mu + sigma * Math.sqrt(-2 * Math.log(rnd() + 1e-9)) * Math.cos(2 * Math.PI * rnd()));
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

// ── State ───────────────────────────────────────────────────────────────────
type Wallet = { address: string; eth: number };
let demoAccount: Wallet | null = null;
const state = {
  tokens: [] as Token[],
  wallet: null as Wallet | null,
  watch: new Set<string>(loadWatch()),
  totalPlatformFees: 0,
  graduations: [] as { id: string; t: number }[],
  version: 0,
};
const listeners = new Set<() => void>();
const emit = () => { state.version++; listeners.forEach((l) => l()); };

function loadWatch(): string[] {
  try { return JSON.parse(localStorage.getItem("mintmark.watch") ?? "[]"); } catch { return []; }
}
function saveWatch() {
  try { localStorage.setItem("mintmark.watch", JSON.stringify([...state.watch])); } catch { /* private mode */ }
}

/** Subscribe to the market; re-renders on every tick. `select` runs against the live state. */
export function useMarket<T>(select: (s: typeof state) => T): T {
  useSyncExternalStore((l) => (listeners.add(l), () => listeners.delete(l)), () => state.version);
  return select(state);
}
export const getToken = (id: string) => state.tokens.find((t) => t.id === id || t.ticker.toLowerCase() === id.toLowerCase());

// ── Trading primitives ──────────────────────────────────────────────────────
function applyBuy(t: Token, wallet: string, ethIn: number, when: number, sealed = false): Trade | null {
  if (t.graduated || ethIn <= 0) return null;
  const q = quoteBuy(t, ethIn);
  if (q.tokens <= 0) return null;
  t.sold += q.tokens;
  t.holders[wallet] = (t.holders[wallet] ?? 0) + q.tokens;
  t.creatorAccrued += q.creatorFee;
  t.platformFees += q.platformFee;
  state.totalPlatformFees += q.platformFee;
  const tr: Trade = { t: when, side: "buy", eth: q.ethUsed, tokens: q.tokens, price: priceAt(t.sold), wallet, sealed };
  t.trades.push(tr);
  if (t.sold >= CURVE_SUPPLY - 1) graduate(t, when);
  return tr;
}

function applySell(t: Token, wallet: string, tokens: number, when: number): Trade | null {
  const have = t.holders[wallet] ?? 0;
  tokens = Math.min(tokens, have);
  if (t.graduated || tokens <= 1) return null;
  const q = quoteSell(t, tokens);
  t.sold -= tokens;
  t.holders[wallet] = have - tokens;
  t.creatorAccrued += q.creatorFee;
  t.platformFees += q.platformFee;
  state.totalPlatformFees += q.platformFee;
  const tr: Trade = { t: when, side: "sell", eth: q.eth, tokens, price: priceAt(t.sold), wallet };
  t.trades.push(tr);
  return tr;
}

function graduate(t: Token, when: number) {
  t.graduated = true;
  t.graduatedAt = when;
  state.graduations.push({ id: t.id, t: when });
}

/** Sealed window close: every order fills at one clearing price, in one batch. */
function clearSealed(t: Token) {
  if (!t.sealed.length) return;
  const orders = t.sealed;
  t.sealed = [];
  const total = orders.reduce((a, o) => a + o.eth, 0);
  const q = quoteBuy(t, total);
  const fill = q.tokens / total; // tokens per HYPE, identical for every order
  const clearing = (q.ethUsed - q.fee) / q.tokens;
  t.sold += q.tokens;
  t.creatorAccrued += q.creatorFee;
  t.platformFees += q.platformFee;
  state.totalPlatformFees += q.platformFee;
  for (const o of orders) {
    t.holders[o.wallet] = (t.holders[o.wallet] ?? 0) + o.eth * fill;
    t.trades.push({ t: t.sealedUntil, side: "buy", eth: o.eth * q.ethUsed / total, tokens: o.eth * fill, price: clearing, wallet: o.wallet, sealed: true });
  }
  if (demoAccount && orders.some((o) => o.wallet === demoAccount!.address)) {
    // Refund anything the curve could not absorb (only if the batch alone would graduate it).
    const unused = total - q.ethUsed;
    if (unused > 0) demoAccount.eth += unused * orders.filter((o) => o.wallet === demoAccount!.address).reduce((a, o) => a + o.eth, 0) / total;
  }
  if (t.sold >= CURVE_SUPPLY - 1) graduate(t, t.sealedUntil);
}

// ── Seeding: build each sample launch's history by actually trading it ─────
const BLURBS = [
  "Forged in the fires of Elysium. No roadmap, only vibes.",
  "Community meme. Creator fees are claimable as they accrue.",
  "The hottest metal on Elysium.",
  "A demo market on the Elysium curve. Hold the line.",
  "Built for the curve. Destined for configured Elysium DEX.",
];

function makeToken(name: string, ticker: string, createdAt: number, creator: string, image: string | null = null, desc?: string, creatorFeeBps = 0): Token {
  return {
    id: ticker.toLowerCase() + "-" + hex(4),
    name, ticker, image, creator, createdAt,
    desc: desc ?? BLURBS[Math.floor(rnd() * BLURBS.length)],
    sold: 0, graduated: false, sealedUntil: createdAt + SEALED_MS, sealed: [],
    trades: [], holders: {}, creatorFeeBps, creatorRecipient: creator, creatorAccrued: 0, creatorClaimed: 0, platformFees: 0, links: {},
  };
}

function seedMarket() {
  const now = Date.now();
  for (const l of LAUNCHES) {
    const createdAt = now - l.ageMin * 60_000;
    const t = makeToken(l.name, l.ticker, createdAt, someone());
    const target = l.graduated ? CURVE_SUPPLY : Math.max(l.progress, 0.03) * CURVE_SUPPLY;
    const span = (l.graduated ? l.ageMin * 0.7 : l.ageMin) * 60_000;
    // Sealed window: creator and early crowd, one clearing price.
    t.sealed.push({ wallet: t.creator, eth: (0.05 + rnd() * 0.25) * CROWD_TRADE_SCALE });
    for (let i = 0; i < 3 + rnd() * 10; i++) t.sealed.push({ wallet: someone(), eth: (0.01 + rnd() * 0.15) * CROWD_TRADE_SCALE });
    clearSealed(t);
    let when = t.sealedUntil;
    let n = 0;
    while (!t.graduated && t.sold < target && n++ < 500) {
      when = Math.min(when + (span / 160) * (0.3 + rnd() * 1.4), now - 2000);
      if (rnd() < 0.24) {
        const holders = Object.keys(t.holders);
        const w = holders[Math.floor(rnd() * holders.length)];
        applySell(t, w, (t.holders[w] ?? 0) * (0.2 + rnd() * 0.8), when);
      } else {
        applyBuy(t, someone(), Math.min(lognormal(-3.2, 1.0), 0.8) * CROWD_TRADE_SCALE, when);
      }
    }
    state.tokens.push(t);
  }
}

// ── Live simulation ─────────────────────────────────────────────────────────
const FRESH_NAMES = [
  ["Pixel Pepe", "PXPEP"], ["Block Boi", "BBOI"], ["Proof Puppy", "PUPPY"], ["Dither Dog", "DITH"],
  ["Sepolia Sam", "SSAM"], ["Chicago Cat", "CHICA"], ["Burn Bro", "BURN"], ["Gas Gremlin", "GREM"],
  ["Hype Llama", "LLAMA"], ["Curve Kid", "CKID"], ["Orbit Zebra", "ZEBRA"], ["Anvil Ape", "ANVIL"],
];
let freshIdx = 0;

function tick() {
  const now = Date.now();
  for (const t of state.tokens) if (t.sealed.length && now >= t.sealedUntil) clearSealed(t);

  // A new launch every so often, so there is always a sealed window to watch.
  if (rnd() < 0.035) {
    const [name, ticker] = FRESH_NAMES[freshIdx++ % FRESH_NAMES.length];
    const t = makeToken(name, freshIdx > FRESH_NAMES.length ? ticker + freshIdx : ticker, now, someone());
    t.sealed.push({ wallet: t.creator, eth: (0.05 + rnd() * 0.2) * CROWD_TRADE_SCALE });
    state.tokens.push(t);
  }

  // Crowd joins open sealed windows.
  for (const t of state.tokens) if (now < t.sealedUntil && rnd() < 0.5) t.sealed.push({ wallet: someone(), eth: (0.01 + rnd() * 0.12) * CROWD_TRADE_SCALE });

  // Curve trades, weighted toward tokens with momentum.
  const live = state.tokens.filter((t) => !t.graduated && now >= t.sealedUntil);
  for (let i = 0; i < 2; i++) {
    const t = live[Math.floor(Math.pow(rnd(), 0.7) * live.length)];
    if (!t) break;
    const p = progressOf(t);
    if (rnd() < 0.3) {
      const holders = Object.keys(t.holders).filter((w) => w !== demoAccount?.address);
      const w = holders[Math.floor(rnd() * holders.length)];
      if (w) applySell(t, w, (t.holders[w] ?? 0) * (0.2 + rnd() * 0.8), now);
    } else {
      applyBuy(t, someone(), Math.min(lognormal(-3.4 + p, 0.9), 0.9) * CROWD_TRADE_SCALE, now);
    }
  }
  emit();
}

// ── User actions (demo wallet) ──────────────────────────────────────────────
export function connectDemo() {
  demoAccount ??= { address: newWallet(), eth: 1 };
  state.wallet = demoAccount;
  emit();
}
export function disconnect() { state.wallet = null; emit(); }
export function refill() { if (state.wallet) { state.wallet.eth += 1; emit(); } }

export type ActionResult = { ok: true; msg: string } | { ok: false; msg: string };

export function buy(t: Token, eth: number): ActionResult {
  const w = state.wallet;
  if (!w) return { ok: false, msg: "Connect the demo wallet first." };
  if (!Number.isFinite(eth) || eth <= 0) return { ok: false, msg: "Enter an amount." };
  if (eth > w.eth + 1e-12) return { ok: false, msg: "Not enough demo HYPE." };
  if (Date.now() < t.sealedUntil) {
    w.eth -= eth;
    t.sealed.push({ wallet: w.address, eth });
    emit();
    return { ok: true, msg: `Sealed order placed. It fills at the clearing price when the window closes.` };
  }
  const tr = applyBuy(t, w.address, eth, Date.now());
  if (!tr) return { ok: false, msg: "This demo curve has closed. No real DEX pool was created." };
  w.eth -= tr.eth;
  emit();
  return { ok: true, msg: `Bought ${fmtTokens(tr.tokens)} $${t.ticker}.` };
}

export function sell(t: Token, tokens: number): ActionResult {
  const w = state.wallet;
  if (!w) return { ok: false, msg: "Connect the demo wallet first." };
  if (!Number.isFinite(tokens) || tokens <= 0) return { ok: false, msg: "Enter an amount." };
  if (Date.now() < t.sealedUntil) return { ok: false, msg: "Selling opens when the sealed window closes." };
  const tr = applySell(t, w.address, tokens, Date.now());
  if (!tr) return { ok: false, msg: t.graduated ? "This demo curve has closed. No real DEX pool was created." : "Nothing to sell." };
  w.eth += tr.eth;
  emit();
  return { ok: true, msg: `Sold for ${tr.eth.toFixed(4)} HYPE.` };
}

export function launch(input: { name: string; ticker: string; desc: string; image: string | null; x?: string; site?: string; initialBuy: number; creatorFeeBps?: number }): ActionResult & { id?: string } {
  const w = state.wallet;
  if (!w) return { ok: false, msg: "Connect the demo wallet first." };
  const creatorFeeBps = input.creatorFeeBps ?? 0;
  if (!Number.isInteger(creatorFeeBps) || creatorFeeBps < 0 || creatorFeeBps > MAX_CREATOR_FEE_BPS) return { ok: false, msg: "Choose a creator fee from 0% to 10% in 0.01% steps." };
  if (!Number.isFinite(input.initialBuy) || input.initialBuy < 0) return { ok: false, msg: "Enter a valid initial buy." };
  if (input.initialBuy > w.eth) return { ok: false, msg: "Not enough demo HYPE for the initial buy." };
  const t = makeToken(input.name, input.ticker, Date.now(), w.address, input.image, input.desc || undefined, creatorFeeBps);
  t.links = { x: input.x, site: input.site };
  if (input.initialBuy > 0) {
    w.eth -= input.initialBuy;
    t.sealed.push({ wallet: w.address, eth: input.initialBuy });
  }
  state.tokens.push(t);
  emit();
  return { ok: true, msg: "Launched.", id: t.id };
}

/** Demo-only payout. The launch recipient is fixed, and claiming never affects curve reserves. */
export function claimCreatorFees(t: Token): ActionResult {
  const w = state.wallet;
  if (!w) return { ok: false, msg: "Connect the demo wallet first." };
  if (!state.tokens.includes(t) || w.address !== t.creatorRecipient) return { ok: false, msg: "Only this launch's saved creator demo account can claim here." };
  const amount = t.creatorAccrued;
  if (!(amount > 0)) return { ok: false, msg: "No demo creator fees to claim." };
  t.creatorAccrued = 0;
  t.creatorClaimed += amount;
  w.eth += amount;
  emit();
  return { ok: true, msg: `Claimed ${fmtEth(amount, 6)} to your saved creator demo account. No onchain transaction.` };
}

export function toggleWatch(id: string) {
  if (state.watch.has(id)) state.watch.delete(id);
  else state.watch.add(id);
  saveWatch();
  emit();
}

// ── Formatting ──────────────────────────────────────────────────────────────
const SUB = "₀₁₂₃₄₅₆₇₈₉";
export function fmtPrice(p: number) {
  if (p >= 0.001) return p.toFixed(5);
  const zeros = Math.floor(-Math.log10(p)) - 1;
  const digits = Math.round(p * 10 ** (zeros + 3)).toString();
  return `0.0${String(zeros).split("").map((d) => SUB[+d]).join("")}${digits}`;
}
export const fmtEth = (n: number, d = 3) => `${n.toFixed(d)} HYPE`;
export const fmtUsd = (n: number) => "$" + new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(n);
export const fmtTokens = (n: number) => new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 }).format(n);
export const fmtPct = (n: number) => `${n >= 0 ? "+" : ""}${(n * 100).toFixed(1)}%`;
export function fmtAge(ms: number) {
  const m = Math.floor(ms / 60_000);
  if (m < 1) return `${Math.max(1, Math.floor(ms / 1000))}s`;
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// ── Boot ────────────────────────────────────────────────────────────────────
seedMarket();
setInterval(tick, 1300);
