import { useState } from "react";
import { Win } from "../ui/Win";
import { go } from "../ui/router";
import { CoinIcon } from "./CoinIcon";
import { ditherImage } from "./dither";
import { useMarket, launch, connectDemo, fmtEth, quoteBuy, fmtTokens, SEALED_MS, PLATFORM_FEE_BPS, short, type Token } from "./market";
import { GRAD_RAISE, TOTAL_SUPPLY } from "../timeline";

const STEPS = ["Identity", "Story", "Launch", "Review"] as const;

type Draft = { name: string; ticker: string; desc: string; image: string | null; x: string; site: string; initialBuy: string; creatorFee: string };

export function Launch() {
  const wallet = useMarket((s) => s.wallet && { ...s.wallet });
  const [step, setStep] = useState(0);
  const [d, setD] = useState<Draft>({ name: "", ticker: "", desc: "", image: null, x: "", site: "", initialBuy: "0.05", creatorFee: "0" });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: keyof Draft) => (v: string | null) => setD((p) => ({ ...p, [k]: v }));

  const tickerOk = /^[A-Z0-9]{2,8}$/.test(d.ticker);
  const nameOk = d.name.trim().length >= 2 && d.name.trim().length <= 32;
  const buyEth = Math.max(0, parseFloat(d.initialBuy) || 0);
  const creatorFeeBps = Math.round(Number(d.creatorFee) * 100);
  const feeValid = /^\d+(?:\.\d{1,2})?$/.test(d.creatorFee) && creatorFeeBps >= 0 && creatorFeeBps <= 1000;
  const buyValid = d.initialBuy.trim() === "" || (Number.isFinite(Number(d.initialBuy)) && Number(d.initialBuy) >= 0);
  const canNext = step === 0 ? nameOk && tickerOk : step === 2 ? feeValid && buyValid : true;

  const onFile = async (f?: File) => {
    if (!f) return;
    if (!f.type.startsWith("image/")) return setErr("That file isn't an image.");
    if (f.size > 8 * 1024 * 1024) return setErr("Keep images under 8 MB.");
    setErr(null);
    set("image")(await ditherImage(f));
  };

  const submit = () => {
    if (!wallet) return;
    setBusy(true);
    const r = launch({ name: d.name.trim(), ticker: d.ticker, desc: d.desc.trim(), image: d.image, x: d.x.trim() || undefined, site: d.site.trim() || undefined, initialBuy: buyEth, creatorFeeBps });
    setBusy(false);
    if (!r.ok) return setErr(r.msg);
    go(`/app/t/${r.id}`);
  };

  // Estimate what the creator's window buy gets if nobody else joins (the real fill is shared at one price).
  const fresh = { sold: 0, creatorFeeBps: feeValid ? creatorFeeBps : 0 } as Token;
  const est = buyEth > 0 ? quoteBuy(fresh, buyEth) : null;

  return (
    <div className="launch">
      <div className="launch-head">
        <p className="kicker mono">LAUNCH / NEW MEME</p>
        <h1 className="mega-2">Mint a meme.</h1>
      </div>

      <div className="launch-grid">
        <Win title="New Token" meta={`Step ${step + 1} of ${STEPS.length}`} drag={false} className="w-wizard">
          <div className="wizard">
            <ol className="steps" aria-label="Steps">
              {STEPS.map((s, i) => (
                <li key={s} className={i === step ? "on" : i < step ? "done" : ""} aria-current={i === step ? "step" : undefined}>
                  <span className="n mono">{i < step ? "✓" : i + 1}</span>{s}
                </li>
              ))}
            </ol>

            <div className="pane">
              {step === 0 && (
                <div className="fields">
                  <label>
                    <span className="px">NAME</span>
                    <input className="field" value={d.name} maxLength={32} onChange={(e) => set("name")(e.target.value)} placeholder="Pixel Pepe" autoFocus />
                  </label>
                  <label>
                    <span className="px">TICKER</span>
                    <div className="field-row">
                      <span className="unit mono">$</span>
                      <input className="field mono" value={d.ticker} maxLength={8} onChange={(e) => set("ticker")(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, ""))} placeholder="PXPEP" />
                    </div>
                    <small className={`mono hint ${d.ticker && !tickerOk ? "bad" : ""}`}>2 to 8 letters or numbers.</small>
                  </label>
                  <label className="drop">
                    <span className="px">IMAGE</span>
                    <div className="dropzone" onDragOver={(e) => e.preventDefault()} onDrop={(e) => { e.preventDefault(); onFile(e.dataTransfer.files[0]); }}>
                      {d.image ? <img src={d.image} alt="Dithered preview" /> : <span className="dither-thumb big" aria-hidden="true" />}
                      <span>
                        <b>{d.image ? "Dithered to the Elysium palette" : "Drop an image or click to pick"}</b>
                        <small className="mono">Any image works. We dither it to 1-bit.</small>
                      </span>
                      <input type="file" accept="image/*" onChange={(e) => onFile(e.target.files?.[0])} aria-label="Upload image" />
                    </div>
                  </label>
                </div>
              )}

              {step === 1 && (
                <div className="fields">
                  <label>
                    <span className="px">DESCRIPTION</span>
                    <textarea className="field" rows={4} maxLength={280} value={d.desc} onChange={(e) => set("desc")(e.target.value)} placeholder="What is this meme about?" />
                    <small className="mono hint">{d.desc.length}/280</small>
                  </label>
                  <label>
                    <span className="px">X / TWITTER <em>optional</em></span>
                    <input className="field mono" value={d.x} onChange={(e) => set("x")(e.target.value)} placeholder="@yourmeme" />
                  </label>
                  <label>
                    <span className="px">WEBSITE <em>optional</em></span>
                    <input className="field mono" value={d.site} onChange={(e) => set("site")(e.target.value)} placeholder="https://" />
                  </label>
                </div>
              )}

              {step === 2 && (
                <div className="fields">
                  <div className="info-row">
                    <span className="cb on" aria-hidden="true" />
                    <p><b>Demo-only sealed launch window, {SEALED_MS / 1000}s.</b> Demo orders batch for one minute and fill at one clearing price. They are stored in your browser and are not private.</p>
                  </div>
                  <label>
                    <span className="px">YOUR INITIAL BUY <em>optional</em></span>
                    <div className="field-row">
                      <input className="field mono" inputMode="decimal" value={d.initialBuy} onChange={(e) => set("initialBuy")(e.target.value)} />
                      <span className="unit mono">HYPE</span>
                    </div>
                    <small className="mono hint">
                      Joins the sealed window at the same price as everyone.
                      {est ? ` Alone it would get about ${fmtTokens(est.tokens)} tokens (${((est.tokens / TOTAL_SUPPLY) * 100).toFixed(2)}%).` : ""}
                    </small>
                  </label>
                  <label>
                    <span className="px">CREATOR FEE · CURVE ONLY</span>
                    <div className="field-row">
                      <input className="field mono" type="number" min="0" max="10" step="0.01" value={d.creatorFee} onChange={(e) => set("creatorFee")(e.target.value)} aria-label="Creator fee percent" />
                      <span className="unit mono">%</span>
                    </div>
                    <small className={`mono hint ${feeValid ? "" : "bad"}`}>0–10% in 0.01% steps. Locked at launch. {feeValid ? `Combined curve fee: ${((PLATFORM_FEE_BPS + creatorFeeBps) / 100).toFixed(2)}% (0.50% platform + ${d.creatorFee}% creator).` : "Enter a valid fee."}</small>
                  </label>
                  <div className="info-row">
                    <span className="cb on" aria-hidden="true" />
                    <p><b>Claim fees on your token page.</b> Demo fees accrue to your saved creator account and can be claimed before or after graduation. No real HYPE is sent. Fees stop when the curve closes; ordinary V2 pool swaps do not continue this creator fee.</p>
                  </div>
                </div>
              )}

              {step === 3 && (
                <div className="review">
                  <dl className="kv mono">
                    <dt>NAME</dt><dd>{d.name}</dd>
                    <dt>TICKER</dt><dd>${d.ticker}</dd>
                    <dt>SUPPLY</dt><dd>1,000,000,000 · fixed</dd>
                    <dt>LAUNCH</dt><dd>Gas only</dd>
                    <dt>WINDOW</dt><dd>{SEALED_MS / 1000}s · demo only</dd>
                    <dt>CURVE FEES</dt><dd>{((PLATFORM_FEE_BPS + creatorFeeBps) / 100).toFixed(2)}% total · {d.creatorFee}% creator · locked</dd>
                    <dt>RECIPIENT</dt><dd>{wallet ? short(wallet.address) + " · your demo account" : "Connect demo wallet"}</dd>
                    <dt>YOUR BUY</dt><dd>{buyEth > 0 ? fmtEth(buyEth) + " in the window" : "None"}</dd>
                    <dt>ADMIN</dt><dd>None · immutable</dd>
                  </dl>
                  {!wallet && <p className="result err">Connect the demo wallet to launch.</p>}
                </div>
              )}

              {err && <p className="result err" role="alert">{err}</p>}

              <div className="btns end">
                {step > 0 && <button className="btn" onClick={() => setStep(step - 1)}>Back</button>}
                {step < 3 && <button className="btn default" onClick={() => setStep(step + 1)} disabled={!canNext}>Continue</button>}
                {step === 3 && (wallet
                  ? <button className="btn default" onClick={submit} disabled={busy || !feeValid || !buyValid}>Mint it <span className="tag">DEMO</span></button>
                  : <button className="btn default" onClick={connectDemo}>Connect demo wallet</button>)}
              </div>
            </div>
          </div>
        </Win>

        <Win title="Preview" drag={false} className="w-preview">
          <div className="preview-card">
            <CoinIcon token={{ ticker: d.ticker || "TICKR", image: d.image }} size={120} />
            <h2>{d.name || "Your meme"}</h2>
            <p className="mono">${d.ticker || "TICKR"}</p>
            <p className="desc">{d.desc || "Your description shows here."}</p>
            <div className="progress"><div style={{ width: "0%" }} /><span className="mono">000%</span></div>
            <p className="mono small-note">Starts at 0% on the curve. Graduates at {fmtEth(GRAD_RAISE, 0)} net liquidity, excluding trading fees.</p>
          </div>
        </Win>
      </div>
    </div>
  );
}
