import { useEffect, useMemo, useState, type ReactNode } from "react";
import { Win } from "../ui/Win";
import { Link, go } from "../ui/router";
import { CoinIcon } from "./CoinIcon";
import {
  useMarket, stats, type Token, type Stats,
  fmtUsd, fmtPct, fmtEth, fmtAge, short, toggleWatch,
} from "./market";

type Row = { t: Token; s: Stats };
type Col = { key: string; label: string; cell: (r: Row) => ReactNode; num?: boolean };

// A lens is a way of looking at the whole market: its own filter, ranking and columns.
type Lens = {
  id: string;
  name: string;
  glyph: string;
  blurb: string;
  filter: (r: Row, ctx: Ctx) => boolean;
  sort: (a: Row, b: Row) => number;
  cols: string[];
};
type Ctx = { watch: Set<string>; me?: string };

const COLS: Record<string, Col> = {
  mcap: { key: "mcap", label: "MCAP", num: true, cell: (r) => fmtUsd(r.s.mcapUsd) },
  inflow: { key: "inflow", label: "NET IN 1H", num: true, cell: (r) => <span className={r.s.inflow1h >= 0 ? "up" : "down"}>{fmtEth(Math.abs(r.s.inflow1h), 2)}</span> },
  change: { key: "change", label: "1H", num: true, cell: (r) => <span className={r.s.change1h >= 0 ? "up" : "down"}>{fmtPct(r.s.change1h)}</span> },
  curve: { key: "curve", label: "CURVE", cell: (r) => r.t.graduated ? <span className="grad-chip">GRAD</span> : <Bar v={r.s.progress} /> },
  holders: { key: "holders", label: "HOLDERS", num: true, cell: (r) => r.s.holders },
  age: { key: "age", label: "AGE", num: true, cell: (r) => fmtAge(r.s.ageMs) },
  sealed: { key: "sealed", label: "SEALED", num: true, cell: (r) => <SealedCell t={r.t} /> },
  platformFees: { key: "platformFees", label: "PLATFORM FEES", num: true, cell: (r) => fmtEth(r.t.platformFees, 4) },
};

const LENSES: Lens[] = [
  {
    id: "graduating", name: "About to graduate", glyph: "▲",
    blurb: "Closest to the line first. Progress is net HYPE liquidity retained in the curve, excluding trading fees.",
    filter: (r) => !r.t.graduated && !r.s.sealedLive && r.s.progress >= 0.5,
    sort: (a, b) => b.s.progress - a.s.progress,
    cols: ["curve", "mcap", "inflow", "holders", "age"],
  },
  {
    id: "inflow", name: "Net inflow · 1h", glyph: "≈",
    blurb: "Honest trending: HYPE that came in minus HYPE that left in the last hour. Round trips net to zero.",
    filter: (r) => !r.t.graduated && r.s.inflow1h > 0,
    sort: (a, b) => b.s.inflow1h - a.s.inflow1h,
    cols: ["inflow", "change", "curve", "mcap", "age"],
  },
  {
    id: "sealed", name: "Sealed now", glyph: "◘",
    blurb: "Launches still in their 60 second sealed window. Browser-stored demo orders fill at one price; not private.",
    filter: (r) => r.s.sealedLive,
    sort: (a, b) => a.t.sealedUntil - b.t.sealedUntil,
    cols: ["sealed", "age"],
  },
  {
    id: "fresh", name: "Fresh", glyph: "✦",
    blurb: "Newest launches first.",
    filter: (r) => !r.t.graduated,
    sort: (a, b) => b.t.createdAt - a.t.createdAt,
    cols: ["age", "curve", "mcap", "holders"],
  },
  {
    id: "graduated", name: "Graduated", glyph: "◎",
    blurb: "Crossed the line. Demo graduation complete; no real DEX liquidity.",
    filter: (r) => r.t.graduated,
    sort: (a, b) => (b.t.graduatedAt ?? 0) - (a.t.graduatedAt ?? 0),
    cols: ["mcap", "holders", "platformFees", "age"],
  },
  {
    id: "watch", name: "Watchlist", glyph: "★",
    blurb: "Memes you starred. Saved in this browser.",
    filter: (r, c) => c.watch.has(r.t.id),
    sort: (a, b) => b.s.progress - a.s.progress,
    cols: ["curve", "mcap", "change", "age"],
  },
  {
    id: "mine", name: "Mine", glyph: "⌂",
    blurb: "Memes you launched or hold with the demo wallet.",
    filter: (r, c) => !!c.me && (r.t.creator === c.me || (r.t.holders[c.me] ?? 0) > 1 || r.t.sealed.some((o) => o.wallet === c.me)),
    sort: (a, b) => b.t.createdAt - a.t.createdAt,
    cols: ["curve", "mcap", "change", "age"],
  },
];

function Bar({ v }: { v: number }) {
  return <span className="bar" aria-label={`${Math.round(v * 100)}% of curve`}><i style={{ width: `${v * 100}%` }} /><em>{Math.round(v * 100)}%</em></span>;
}

function SealedCell({ t }: { t: Token }) {
  const left = Math.max(0, Math.ceil((t.sealedUntil - Date.now()) / 1000));
  return <span className="sealed-cell">{t.sealed.length} {t.sealed.length === 1 ? "order" : "orders"} · {left}s</span>;
}

function lensFromUrl() {
  const q = new URLSearchParams(location.search).get("lens");
  return LENSES.find((l) => l.id === q)?.id ?? "graduating";
}

export function Discover() {
  const [lensId, setLensId] = useState(lensFromUrl);
  const [view, setView] = useState<"list" | "icons">("list");
  const [q, setQ] = useState("");
  useEffect(() => {
    const on = () => setLensId(lensFromUrl());
    addEventListener("popstate", on);
    return () => removeEventListener("popstate", on);
  }, []);
  const pick = (id: string) => {
    history.replaceState(null, "", `/app?lens=${id}`);
    setLensId(id);
  };

  const { rows, ctx, platformFees, grads } = useMarket((s) => {
    const now = Date.now();
    return {
      rows: s.tokens.map((t) => ({ t, s: stats(t, now) })),
      ctx: { watch: s.watch, me: s.wallet?.address } as Ctx,
      platformFees: s.totalPlatformFees,
      grads: s.graduations.filter((g) => g.t > now - 86_400_000).length,
    };
  });
  const lens = LENSES.find((l) => l.id === lensId)!;
  const counts = useMemo(() => Object.fromEntries(LENSES.map((l) => [l.id, rows.filter((r) => l.filter(r, ctx)).length])), [rows, ctx]);
  const needle = q.trim().toLowerCase();
  const shown = rows
    .filter((r) => lens.filter(r, ctx))
    .filter((r) => !needle || r.t.name.toLowerCase().includes(needle) || r.t.ticker.toLowerCase().includes(needle))
    .sort(lens.sort);

  return (
    <div className="discover">
      <aside className="lenses">
        <Win title="Lenses" drag={false}>
          <ul role="listbox" aria-label="Trading lenses">
            {LENSES.map((l) => (
              <li key={l.id} role="option" aria-selected={l.id === lensId}>
                <button className={l.id === lensId ? "on" : ""} onClick={() => pick(l.id)}>
                  <span className="glyph" aria-hidden="true">{l.glyph}</span>
                  <span className="lname">{l.name}</span>
                  <span className="count mono">{counts[l.id]}</span>
                </button>
              </li>
            ))}
          </ul>
        </Win>
        <Win title="Market" drag={false} className="w-market">
          <dl className="kv mono">
            <dt>LIVE</dt><dd>{rows.filter((r) => !r.t.graduated).length} memes</dd>
            <dt>SEALED</dt><dd>{counts.sealed} open</dd>
            <dt>GRADUATED</dt><dd>{grads} in 24h</dd>
            <dt>PLATFORM FEES</dt><dd>{fmtEth(platformFees, 4)}</dd>
          </dl>
        </Win>
      </aside>

      <section className="lens-main">
        <Win title={lens.name} meta={`${shown.length} items`} drag={false} className="w-lens">
          <div className="toolbar">
            <p className="blurb">{lens.blurb}</p>
            <input className="search mono" placeholder="Search name or $TICKER" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search memes" />
            <div className="seg" role="group" aria-label="View">
              <button className={view === "list" ? "on" : ""} onClick={() => setView("list")} aria-pressed={view === "list"}>List</button>
              <button className={view === "icons" ? "on" : ""} onClick={() => setView("icons")} aria-pressed={view === "icons"}>Icons</button>
            </div>
          </div>

          {shown.length === 0 ? (
            <Empty lens={lens} />
          ) : view === "list" ? (
            <div className="table-wrap">
              <table className="lens-table mono">
                <thead>
                  <tr>
                    <th aria-label="Watch" />
                    <th>MEME</th>
                    {lens.cols.map((c) => <th key={c} className={COLS[c].num ? "num" : ""}>{COLS[c].label}</th>)}
                  </tr>
                </thead>
                <tbody>
                  {shown.slice(0, 60).map((r) => (
                    <tr key={r.t.id} onClick={() => go(`/app/t/${r.t.id}`)}>
                      <td>
                        <button className={`star ${ctx.watch.has(r.t.id) ? "on" : ""}`} aria-label={ctx.watch.has(r.t.id) ? "Remove from watchlist" : "Add to watchlist"}
                          onClick={(e) => { e.stopPropagation(); toggleWatch(r.t.id); }}>★</button>
                      </td>
                      <td>
                        <Link to={`/app/t/${r.t.id}`} className="meme-cell" onClick={(e) => e.stopPropagation()}>
                          <CoinIcon token={r.t} size={30} />
                          <span><b>{r.t.name}</b><small>${r.t.ticker}</small></span>
                        </Link>
                      </td>
                      {lens.cols.map((c) => <td key={c} className={COLS[c].num ? "num" : ""}>{COLS[c].cell(r)}</td>)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <ul className="icon-grid">
              {shown.slice(0, 60).map((r) => (
                <li key={r.t.id}>
                  <Link to={`/app/t/${r.t.id}`}>
                    <CoinIcon token={r.t} size={64} />
                    <b>{r.t.name}</b>
                    <small className="mono">{r.t.graduated ? "GRADUATED" : r.s.sealedLive ? "SEALED" : `${Math.round(r.s.progress * 100)}% · ${fmtUsd(r.s.mcapUsd)}`}</small>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Win>
      </section>

      <aside className="tape-col">
        <Tape />
      </aside>
    </div>
  );
}

function Empty({ lens }: { lens: Lens }) {
  const msg: Record<string, ReactNode> = {
    watch: <>Nothing starred yet. Tap the ★ on any meme to watch it here.</>,
    mine: <>Connect the demo wallet, then <Link to="/app/launch">launch a meme</Link> or buy one.</>,
    sealed: <>No windows open right now. New launches appear here for their first 60 seconds.</>,
  };
  return <div className="empty"><span className="empty-icon" aria-hidden="true">{lens.glyph}</span><p>{msg[lens.id] ?? "Nothing here yet."}</p></div>;
}

function Tape() {
  const trades = useMarket((s) => {
    const all: { t: Token; side: string; eth: number; wallet: string; at: number; sealed?: boolean }[] = [];
    for (const t of s.tokens) for (let i = Math.max(0, t.trades.length - 4); i < t.trades.length; i++) {
      const tr = t.trades[i];
      all.push({ t, side: tr.side, eth: tr.eth, wallet: tr.wallet, at: tr.t, sealed: tr.sealed });
    }
    return all.sort((a, b) => b.at - a.at).slice(0, 14);
  });
  const now = Date.now();
  return (
    <Win title="Tape" meta="LIVE" drag={false} className="w-tape">
      <ol className="tape mono">
        {trades.map((x, i) => (
          <li key={`${x.t.id}-${x.at}-${i}`}>
            <Link to={`/app/t/${x.t.id}`}>
              <span className={`side ${x.side}`}>{x.sealed ? "SEAL" : x.side === "buy" ? "BUY" : "SELL"}</span>
              <b>${x.t.ticker}</b>
              <span>{fmtEth(x.eth, 3)}</span>
              <small>{short(x.wallet)} · {fmtAge(now - x.at)}</small>
            </Link>
          </li>
        ))}
      </ol>
    </Win>
  );
}
