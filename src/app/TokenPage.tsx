import { useState } from "react";
import { Win } from "../ui/Win";
import { Link } from "../ui/router";
import { CoinIcon } from "./CoinIcon";
import { Chart } from "./Chart";
import {
  useMarket, getToken, stats, quoteBuy, quoteSell, buy, sell, connectDemo, toggleWatch, claimCreatorFees, feeRate,
  type Token, fmtEth, fmtUsd, fmtPct, fmtPrice, fmtTokens, fmtAge, short, SEALED_MS,
} from "./market";
import { GRAD_RAISE, TOTAL_SUPPLY } from "../timeline";

const FRAMES = [
  { label: "Auto", ms: 0 }, // fits the meme's whole life into the chart
  { label: "1m", ms: 60_000 },
  { label: "5m", ms: 300_000 },
  { label: "15m", ms: 900_000 },
  { label: "1h", ms: 3_600_000 },
];

/** Bucket size so ~56 candles cover the meme's life (graduated memes: up to graduation). */
function autoBucket(t: Token) {
  const end = t.graduatedAt ?? Date.now();
  const life = Math.max(end - t.createdAt, 60_000);
  const steps = [15_000, 60_000, 300_000, 900_000, 3_600_000, 14_400_000];
  return steps.find((s) => life / s <= 56) ?? steps[steps.length - 1];
}

export function TokenPage({ id }: { id: string }) {
  const snap = useMarket((s) => {
    const t = getToken(id);
    return t ? { t, s: stats(t), watched: s.watch.has(t.id), me: s.wallet?.address, myEth: s.wallet?.eth ?? 0 } : null;
  });
  const [frame, setFrame] = useState(0);
  const [claimResult, setClaimResult] = useState<{ ok: boolean; msg: string } | null>(null);

  if (!snap) {
    return (
      <div className="token-missing">
        <Win title="Not found" drag={false}>
          <p>No meme called <b>{id}</b> on this demo market. <Link to="/app">Back to Discover</Link></p>
        </Win>
      </div>
    );
  }
  const { t, s, watched, me, myEth } = snap;
  if (document.title !== `$${t.ticker} · MintMark`) document.title = `$${t.ticker} · MintMark`;
  const mine = me ? t.holders[me] ?? 0 : 0;
  const myPending = me ? t.sealed.filter((o) => o.wallet === me).reduce((a, o) => a + o.eth, 0) : 0;

  return (
    <div className="token-page">
      <header className="token-head">
        <CoinIcon token={t} size={72} />
        <div>
          <p className="kicker mono">
            <Link to="/app">Discover</Link> / ${t.ticker} · {t.graduated ? "GRADUATED" : s.sealedLive ? "SEALED WINDOW" : "ON CURVE"}
          </p>
          <h1 className="token-title">{t.name} <span className="mono">${t.ticker}</span></h1>
          <p className="token-meta mono">
            {fmtUsd(s.mcapUsd)} mcap · price {fmtPrice(s.price)} HYPE · <span className={s.change1h >= 0 ? "up" : "down"}>{fmtPct(s.change1h)}</span> 1h · {s.holders} holders · {fmtAge(s.ageMs)} old
          </p>
        </div>
        <button className={`btn star-btn ${watched ? "on" : ""}`} onClick={() => toggleWatch(t.id)} aria-pressed={watched}>
          {watched ? "★ Watching" : "☆ Watch"}
        </button>
      </header>

      <div className="token-grid">
        <div className="col-main">
          <Win title="Chart" meta={t.graduated ? "curve closed" : "DEMO"} drag={false} className="w-chart">
            <div className="seg frames" role="group" aria-label="Timeframe">
              {FRAMES.map((f, i) => (
                <button key={f.label} className={frame === i ? "on" : ""} onClick={() => setFrame(i)} aria-pressed={frame === i}>{f.label}</button>
              ))}
            </div>
            <Chart token={t} bucket={FRAMES[frame].ms || autoBucket(t)} now={Date.now()} />
          </Win>

          <Win title="Trades" meta={`${t.trades.length} total`} drag={false} className="w-trades">
            <table className="trades mono">
              <thead><tr><th>SIDE</th><th className="num">HYPE</th><th className="num">TOKENS</th><th className="num">PRICE</th><th>WALLET</th><th className="num">AGE</th></tr></thead>
              <tbody>
                {t.trades.slice(-14).reverse().map((tr, i) => (
                  <tr key={`${tr.t}-${i}`} className={tr.wallet === me ? "me" : ""}>
                    <td><span className={`side ${tr.side}`}>{tr.sealed ? "SEAL" : tr.side.toUpperCase()}</span></td>
                    <td className="num">{tr.eth.toFixed(4)}</td>
                    <td className="num">{fmtTokens(tr.tokens)}</td>
                    <td className="num">{fmtPrice(tr.price)}</td>
                    <td>{tr.wallet === me ? "you" : tr.wallet === t.creator ? `${short(tr.wallet)} · creator` : short(tr.wallet)}</td>
                    <td className="num">{fmtAge(Date.now() - tr.t)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Win>
        </div>

        <div className="col-side">
          <TradePanel t={t} myEth={myEth} mine={mine} pending={myPending} connected={!!me} sealedLive={s.sealedLive} />

          <Win title="Curve" drag={false} className="w-curve-info">
            {t.graduated ? (
              <p className="grad-note">Graduated {fmtAge(Date.now() - (t.graduatedAt ?? Date.now()))} ago. Demo graduation complete. No real liquidity was moved.</p>
            ) : (
              <>
                <div className="progress big" aria-label={`${Math.round(s.progress * 100)}% to graduation`}>
                  <div style={{ width: `${s.progress * 100}%` }} />
                  <span className="mono">{Math.round(s.progress * 100)}%</span>
                </div>
                <p className="mono small-note">{fmtEth(s.raised, 3)} of {fmtEth(GRAD_RAISE, 0)} net liquidity target, excluding trading fees. Demo graduation simulates migration to the configured Elysium DEX; no real liquidity is moved.</p>
              </>
            )}
            <dl className="kv mono">
              <dt>CREATOR</dt><dd>{short(t.creator)}{t.creator === me ? " (you)" : ""}</dd>
              <dt>CURVE FEES</dt><dd>{(feeRate(t) * 100).toFixed(2)}% total · 0.50% platform + {(t.creatorFeeBps / 100).toFixed(2)}% creator</dd>
              <dt>RECIPIENT</dt><dd title={t.creatorRecipient}>{short(t.creatorRecipient)} · demo</dd>
              <dt>CLAIMABLE</dt><dd>{fmtEth(t.creatorAccrued, 6)}</dd>
              <dt>CLAIMED</dt><dd>{fmtEth(t.creatorClaimed, 6)}</dd>
            </dl>
            <p className="mono small-note">Creator fee locked at launch, curve trades only. Claimable before and after graduation to the saved demo recipient. No real funds or transaction. Ordinary V2 pool swaps do not continue this creator fee.</p>
            {!me ? <button className="btn wide" onClick={connectDemo}>Connect demo wallet to claim</button> : <button className="btn wide" disabled={me !== t.creatorRecipient || t.creatorAccrued <= 0} onClick={() => setClaimResult(claimCreatorFees(t))}>Claim demo creator fees</button>}
            {me && me !== t.creatorRecipient && <p className="mono small-note">Connect the creator demo account to claim this launch's fees.</p>}
            {claimResult && <p className={`result ${claimResult.ok ? "ok" : "err"}`} role="status">{claimResult.msg}</p>}
          </Win>

          <Holders t={t} me={me} />

          <Win title="About" drag={false} className="w-about">
            <p>{t.desc}</p>
            {(t.links.x || t.links.site) && (
              <p className="mono small-note">
                {t.links.x && <>X: {t.links.x} </>}{t.links.site && <>· {t.links.site}</>}
              </p>
            )}
            <p className="mono small-note">Simulated token, not an onchain contract. Live deployment and security audit are pending.</p>
          </Win>
        </div>
      </div>
    </div>
  );
}

function TradePanel({ t, myEth, mine, pending, connected, sealedLive }: {
  t: Token; myEth: number; mine: number; pending: number; connected: boolean; sealedLive: boolean;
}) {
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [amt, setAmt] = useState("0.05");
  const [msg, setMsg] = useState<{ ok: boolean; msg: string } | null>(null);
  const n = Math.max(0, parseFloat(amt) || 0);
  const left = Math.max(0, Math.ceil((t.sealedUntil - Date.now()) / 1000));

  if (t.graduated) {
    return (
      <Win title="Trade" drag={false} className="w-trade">
        <p>This demo meme graduated. No real DEX pool was created.</p>
        <p className="mono small-note">configured Elysium DEX routing arrives with the live contracts.</p>
      </Win>
    );
  }

  const qb = side === "buy" ? quoteBuy(t, n) : null;
  const tokensIn = side === "sell" ? mine * Math.min(n, 100) / 100 : 0;
  const qs = side === "sell" ? quoteSell(t, tokensIn) : null;

  const submit = () => {
    const r = side === "buy" ? buy(t, n) : sell(t, tokensIn);
    setMsg(r);
  };

  return (
    <Win title="Trade" meta={sealedLive ? `SEALED · ${left}s` : "CURVE"} drag={false} className="w-trade">
      <div className="seg full" role="tablist" aria-label="Side">
        <button role="tab" aria-selected={side === "buy"} className={side === "buy" ? "on" : ""} onClick={() => { setSide("buy"); setAmt("0.05"); setMsg(null); }}>Buy</button>
        <button role="tab" aria-selected={side === "sell"} className={side === "sell" ? "on" : ""} onClick={() => { setSide("sell"); setAmt("50"); setMsg(null); }} disabled={sealedLive}>Sell</button>
      </div>

      {sealedLive && (
        <p className="sealed-note mono">
          Sealed window: {t.sealed.length} demo {t.sealed.length === 1 ? "order" : "orders"}. Yours fills with everyone else's at one price in {left}s.
        </p>
      )}

      <label className="amount">
        <span className="px">{side === "buy" ? "YOU PAY" : "YOU SELL"}</span>
        <div className="field-row">
          <input className="field mono" inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} aria-label={side === "buy" ? "HYPE to spend" : "Percent of your tokens to sell"} />
          <span className="unit mono">{side === "buy" ? "HYPE" : "%"}</span>
        </div>
      </label>
      <div className="quick">
        {(side === "buy" ? ["0.01", "0.05", "0.1", "0.5"] : ["25", "50", "75", "100"]).map((v) => (
          <button key={v} className="chip mono" onClick={() => setAmt(v)}>{side === "buy" ? `${v} HYPE` : `${v}%`}</button>
        ))}
      </div>

      <dl className="quote mono">
        {side === "buy" && qb && (
          <>
            <dt>{sealedLive ? "EST. RECEIVE" : "RECEIVE"}</dt><dd>{fmtTokens(qb.tokens)} ${t.ticker}</dd>
            <dt>AVG PRICE</dt><dd>{fmtPrice(qb.avg)} HYPE</dd>
            <dt>IMPACT</dt><dd>{fmtPct(qb.impact)}</dd>
            <dt>FEE {(feeRate(t) * 100).toFixed(2)}%</dt><dd>{fmtEth(qb.fee, 5)}</dd>
            <dt>CREATOR / PLATFORM</dt><dd>{fmtEth(qb.creatorFee, 5)} / {fmtEth(qb.platformFee, 5)}</dd>
            {qb.capped && <><dt>NOTE</dt><dd>Fills the curve. Unused HYPE stays in your wallet.</dd></>}
          </>
        )}
        {side === "sell" && qs && (
          <>
            <dt>SELLING</dt><dd>{fmtTokens(tokensIn)} ${t.ticker}</dd>
            <dt>RECEIVE</dt><dd>{fmtEth(qs.eth, 5)}</dd>
            <dt>IMPACT</dt><dd>{fmtPct(-qs.impact)}</dd>
            <dt>FEE {(feeRate(t) * 100).toFixed(2)}%</dt><dd>{fmtEth(qs.fee, 5)}</dd>
            <dt>CREATOR / PLATFORM</dt><dd>{fmtEth(qs.creatorFee, 5)} / {fmtEth(qs.platformFee, 5)}</dd>
          </>
        )}
      </dl>

      {connected ? (
        <button className="btn default wide" onClick={submit} disabled={side === "buy" ? n <= 0 : tokensIn <= 1}>
          {side === "buy" ? (sealedLive ? "Place sealed order" : `Buy $${t.ticker}`) : `Sell $${t.ticker}`}
        </button>
      ) : (
        <button className="btn default wide" onClick={connectDemo}>Connect demo wallet</button>
      )}
      {msg && <p className={`result ${msg.ok ? "ok" : "err"}`} role="status">{msg.msg}</p>}

      <p className="mono small-note balances">
        Wallet {fmtEth(myEth)} · holding {fmtTokens(mine)} ${t.ticker}{pending > 0 ? ` · ${fmtEth(pending)} sealed` : ""}
      </p>
      <p className="mono small-note">Demo-only window {SEALED_MS / 1000}s · supply {fmtTokens(TOTAL_SUPPLY)}</p>
    </Win>
  );
}

function Holders({ t, me }: { t: Token; me?: string }) {
  const top = Object.entries(t.holders).filter(([, v]) => v > 1).sort((a, b) => b[1] - a[1]).slice(0, 8);
  return (
    <Win title="Holders" meta="top 8" drag={false} className="w-holders">
      <ol className="holders mono">
        {top.map(([w, v]) => {
          const pct = v / TOTAL_SUPPLY;
          return (
            <li key={w}>
              <span>{w === me ? "you" : short(w)}{w === t.creator ? " · creator" : ""}</span>
              <span className="hbar"><i style={{ width: `${Math.min(pct * 400, 100)}%` }} /></span>
              <span className="num">{(pct * 100).toFixed(2)}%</span>
            </li>
          );
        })}
      </ol>
      <p className="mono small-note">Wallets, not people: one person can hold many. Rankings never use holder counts.</p>
    </Win>
  );
}
