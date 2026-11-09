import { useMemo } from "react";
import type { Token } from "./market";
import { priceAt, fmtPrice } from "./market";
import { CURVE_SUPPLY } from "../timeline";

// 1-bit candles: up = hollow (paper body, ink outline), down = solid ink. Volume in dithered bars.
type Candle = { t: number; o: number; h: number; l: number; c: number; v: number };

function buildCandles(tok: Token, bucket: number, count: number, now: number): Candle[] {
  const end = Math.ceil(now / bucket) * bucket;
  const start = end - bucket * count;
  const out: Candle[] = [];
  let i = 0;
  let last = priceAt(0);
  const trades = tok.trades;
  while (i < trades.length && trades[i].t < start) last = trades[i++].price;
  for (let b = 0; b < count; b++) {
    const t0 = start + b * bucket;
    const t1 = t0 + bucket;
    const c: Candle = { t: t0, o: last, h: last, l: last, c: last, v: 0 };
    while (i < trades.length && trades[i].t < t1) {
      const p = trades[i].price;
      c.h = Math.max(c.h, p);
      c.l = Math.min(c.l, p);
      c.c = p;
      c.v += trades[i].eth;
      i++;
    }
    last = c.c;
    if (t1 > tok.createdAt) out.push(c);
  }
  return out;
}

export function Chart({ token, bucket, now }: { token: Token; bucket: number; now: number }) {
  const W = 640, H = 300, VOL = 54, PAD = 8, AXIS = 64;
  const candles = useMemo(() => buildCandles(token, bucket, 64, now), [token, token.trades.length, bucket, now]);
  const gradPrice = priceAt(CURVE_SUPPLY);
  const lo = Math.min(...candles.map((c) => c.l));
  const hiRaw = Math.max(...candles.map((c) => c.h));
  const hi = Math.max(hiRaw, lo * 1.02);
  const showGrad = !token.graduated && gradPrice < hi * 1.6;
  const top = showGrad ? Math.max(hi, gradPrice) : hi;
  const plotH = H - VOL - PAD * 2;
  const y = (p: number) => PAD + (1 - (Math.log(p) - Math.log(lo)) / (Math.log(top) - Math.log(lo) || 1)) * plotH;
  const cw = (W - AXIS) / 64;
  const vmax = Math.max(...candles.map((c) => c.v), 1e-9);
  const ticks = [lo, Math.sqrt(lo * top), top];

  if (!token.trades.length || !candles.length) return <div className="chart-empty mono">No trades yet. Everything fills at once when the sealed window closes.</div>;

  return (
    <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`$${token.ticker} price chart`}>
      <defs>
        <pattern id="dots" width="3" height="3" patternUnits="userSpaceOnUse">
          <rect width="1.5" height="1.5" fill="var(--ink)" />
        </pattern>
      </defs>
      {ticks.map((p, i) => (
        <g key={i}>
          <line x1={0} x2={W - AXIS} y1={y(p)} y2={y(p)} className="gridline" />
          <text x={W - AXIS + 6} y={y(p) + 4} className="axis">{fmtPrice(p)}</text>
        </g>
      ))}
      {showGrad && (
        <g>
          <line x1={0} x2={W - AXIS} y1={y(gradPrice)} y2={y(gradPrice)} className="gradline" />
          <text x={6} y={y(gradPrice) < 18 ? y(gradPrice) + 14 : y(gradPrice) - 6} className="axis strong">GRADUATION</text>
        </g>
      )}
      {candles.map((c, i) => {
        const x = (64 - candles.length + i) * cw;
        const up = c.c >= c.o;
        const bodyTop = y(Math.max(c.o, c.c));
        const bodyH = Math.max(1.5, y(Math.min(c.o, c.c)) - bodyTop);
        const vh = (c.v / vmax) * (VOL - 6);
        return (
          <g key={c.t}>
            <line x1={x + cw / 2} x2={x + cw / 2} y1={y(c.h)} y2={y(c.l)} className="wick" />
            <rect x={x + 1.5} y={bodyTop} width={cw - 3} height={bodyH} className={up ? "up-body" : "down-body"} />
            {c.v > 0 && <rect x={x + 1.5} y={H - vh} width={cw - 3} height={vh} fill="url(#dots)" />}
          </g>
        );
      })}
      <line x1={0} x2={W - AXIS} y1={H - VOL} y2={H - VOL} className="baseline" />
    </svg>
  );
}
