// Shared scroll state. `beat` is a float: section i is at the top of the viewport at beat = i.
// 0 hero · 1 cast · 2 curve · 3 graduate · 4 live · 5 fees · 6 cta
export const scroll = { beat: 0, velocity: 0, reduced: false };

/** Splash when the coin lands in the pool. Real-time, not scroll-scrubbed: `age` is seconds since impact, -1 when idle. */
export const SPLASH_BEAT = 3.25;
export const splash = { age: -1 };

export const clamp = (x: number, a = 0, b = 1) => Math.min(b, Math.max(a, x));
export const smooth = (e0: number, e1: number, x: number) => {
  const t = clamp((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
};
export const bump = (x: number, a: number, peak: number, b: number) =>
  x < peak ? smooth(a, peak, x) : 1 - smooth(peak, b, x);

// Bonding curve: float illustration of the contract parameters.
// 800M tokens sold leaves 30 HYPE net liquidity, excluding trading fees.
export const V_ETH0 = 10.0000000125;
export const V_TOK0 = 1_066_666_667;
export const CURVE_SUPPLY = 8e8;
export const TOTAL_SUPPLY = 1e9;
const K = V_ETH0 * V_TOK0;

export function curveAt(sold: number) {
  const vT = V_TOK0 - sold;
  const vE = K / vT;
  return { price: vE / vT, raised: vE - V_ETH0 };
}

export const GRAD_RAISE = curveAt(CURVE_SUPPLY).raised;
const P0 = curveAt(0).price;
const P1 = curveAt(CURVE_SUPPLY).price;

// World layout.
export const CURVE_LEN = 8;
export const CURVE_H = 4.2;
export const CURVE_DEPTH = -1.5;
export type Vec3 = { x: number; y: number; z: number; set(x: number, y: number, z: number): Vec3 };
export const POOL_AT = [10.2, -0.4, -1.4] as const;
export const BOARD_AT = [11, 0, -16] as const;
export const CTA_COIN_AT = [11, 3, -10.5] as const;

/** Point on the bonding curve in world space. Kept free of three.js so the page shell stays light. */
export function curvePoint<V extends Vec3>(t: number, out: V): V {
  const n = (curveAt(t * CURVE_SUPPLY).price - P0) / (P1 - P0);
  return out.set(t * CURVE_LEN, n * CURVE_H, t * CURVE_DEPTH) as V;
}

/** Fraction of the curve the coin has climbed. */
export const coinT = (b: number) => smooth(2.0, 2.75, b);

const SUB = "₀₁₂₃₄₅₆₇₈₉";
/** 0.0000000142 → 0.0₈142 */
export function formatTiny(p: number) {
  if (p >= 0.001) return p.toFixed(4);
  const zeros = Math.floor(-Math.log10(p)) - 1;
  const digits = Math.round(p * 10 ** (zeros + 3)).toString();
  return `0.0${String(zeros).split("").map((d) => SUB[+d]).join("")}${digits}`;
}
