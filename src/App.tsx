import { useChainBlock } from "./ui/useChainBlock";
import { elysium } from "./network/elysium";
import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { Win } from "./ui/Win";
import { ThemeToggle } from "./ui/ThemeToggle";
import Lenis from "lenis";
import { scroll, coinT, curveAt, formatTiny, CURVE_SUPPLY, TOTAL_SUPPLY, GRAD_RAISE } from "./timeline";
import { LAUNCHES, fmtUsd, fmtPct, useHover } from "./launches";

const Scene = lazy(() => import("./scene/Scene"));

// Sections that drive 3D beats. The zk section sits between graduate and live without a beat of its own,
// so the camera's pool-to-constellation move plays out while it scrolls past.
const SECTIONS = ["top", "cast", "curve", "graduate", "live", "fees", "forge"];
const VERSION = "v0.1.0-alpha";
const HEX_NAME = "0x6d696e746d61726b"; // "mintmark"
const PROOF = "0x1f9a0c77e2b4d15a9c3e08f6b2d47a1e5c90b3f8d26e4a71c05b9e3d8f2a6c41";

function useMedia(q: string) {
  const [m, setM] = useState(() => window.matchMedia(q).matches);
  useEffect(() => {
    const mq = window.matchMedia(q);
    const on = () => setM(mq.matches);
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, [q]);
  return m;
}


function useClock() {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 15000);
    return () => clearInterval(id);
  }, []);
  return now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function Tooltip() {
  const h = useHover();
  if (!h) return null;
  const l = LAUNCHES[h.id];
  return (
    <div className="tip" style={{ transform: `translate(${h.x + 18}px, ${h.y + 18}px)` }} role="status">
      <div className="win">
        <div className="titlebar"><span className="box" /><span className="title">{l.name}</span></div>
        <dl className="win-body kv mono">
          <dt>TICKER</dt><dd>${l.ticker}</dd>
          <dt>MCAP</dt><dd>{fmtUsd(l.mcapUsd)}</dd>
          <dt>24H</dt><dd className={l.change24h >= 0 ? "up" : "down"}>{fmtPct(l.change24h)}</dd>
          <dt>CURVE</dt><dd>{l.graduated ? "GRADUATED" : `${Math.round(l.progress * 100)}%`}</dd>
        </dl>
      </div>
    </div>
  );
}

const ticker = [...LAUNCHES].sort((a, b) => b.mcapUsd - a.mcapUsd).slice(0, 18);

function Marquee() {
  const items = ticker.map((l) => (
    <span key={l.id}>
      ${l.ticker} <b className={l.change24h >= 0 ? "up" : "down"}>{fmtPct(l.change24h)}</b>
    </span>
  ));
  return (
    <div className="marquee mono" aria-label="Sample launch ticker">
      <div className="marquee-track">{items}{items}</div>
    </div>
  );
}

export default function App() {
  const reduced = useMedia("(prefers-reduced-motion: reduce)");
  const lite = useMedia("(max-width: 760px), (pointer: coarse)");
  const [ready, setReady] = useState(false);
  const block = useChainBlock();
  const clock = useClock();
  const read = {
    sold: useRef<HTMLSpanElement>(null),
    price: useRef<HTMLSpanElement>(null),
    raised: useRef<HTMLSpanElement>(null),
    bar: useRef<HTMLDivElement>(null),
    pct: useRef<HTMLSpanElement>(null),
  };

  useEffect(() => {
    const t = setTimeout(() => setReady(true), 5000);
    return () => clearTimeout(t);
  }, []);

  useEffect(() => {
    scroll.reduced = reduced;
    document.documentElement.classList.toggle("reduced", reduced);
    let tops: number[] = [];
    const measure = () => {
      tops = SECTIONS.map((id) => document.getElementById(id)?.offsetTop ?? 0);
    };
    const update = (y: number) => {
      let b = 0;
      if (!reduced) {
        let i = 0;
        while (i < tops.length - 1 && y >= tops[i + 1]) i++;
        const span = (tops[i + 1] ?? tops[i] + 1) - tops[i];
        b = Math.min(i + (y - tops[i]) / span, SECTIONS.length - 1);
      }
      scroll.beat = b;
      const t = coinT(Math.max(b, 2));
      const sold = t * CURVE_SUPPLY;
      const { price, raised } = curveAt(sold);
      const pct = raised / GRAD_RAISE;
      if (read.sold.current) read.sold.current.textContent = `${((sold / TOTAL_SUPPLY) * 100).toFixed(1)}%`;
      if (read.price.current) read.price.current.textContent = formatTiny(price);
      if (read.raised.current) read.raised.current.textContent = raised.toFixed(3);
      if (read.bar.current) read.bar.current.style.width = `${pct * 100}%`;
      if (read.pct.current) read.pct.current.textContent = `${Math.round(pct * 100).toString().padStart(3, "0")}%`;
    };
    measure();
    const ro = new ResizeObserver(() => { measure(); update(window.scrollY); });
    ro.observe(document.body);

    if (reduced) {
      const on = () => update(window.scrollY);
      window.addEventListener("scroll", on, { passive: true });
      update(window.scrollY);
      return () => { ro.disconnect(); window.removeEventListener("scroll", on); };
    }
    const lenis = new Lenis({ autoRaf: true, lerp: 0.09, anchors: true });
    lenis.on("scroll", (l: Lenis) => { scroll.velocity = l.velocity; update(l.scroll); });
    update(window.scrollY);
    return () => { ro.disconnect(); lenis.destroy(); };
  }, [reduced]);

  return (
    <>
      <div className={`loader ${ready ? "done" : ""}`} aria-hidden={ready}>
        <div className="win loader-win">
          <div className="titlebar"><span className="box" /><span className="title">MINTMARK.SYS</span></div>
          <div className="win-body">
            <p className="px">STRIKING COINS...</p>
            <div className="loader-bar"><i /></div>
            <p className="mono tiny">{VERSION} · {HEX_NAME}</p>
          </div>
        </div>
      </div>

      <Suspense fallback={null}>
        <Scene lite={lite} onReady={() => { document.documentElement.classList.add("webgl"); setReady(true); }} />
      </Suspense>
      <div className="grid-overlay" aria-hidden="true" />
      <Tooltip />

      <header className="menubar">
        <a href="#top" className="brand" aria-label="MintMark home">
          <img src="/favicon.svg" alt="" width={18} height={18} />
          <span>MintMark</span>
        </a>
        <nav aria-label="Sections">
          <a href="#cast">Mint</a>
          <a href="#curve">Curve</a>
          <a href="#zk">Network</a>
          <a href="#live">Memes</a>
          <a href="#fees">Fees</a>
        </nav>
        <div className="status mono">
          <span className="hide-sm">{elysium.name} {elysium.id}</span>
          <span className="hide-sm" title={`Latest verified ${elysium.name} block`}>
            <i className={`led ${block ? "on" : ""}`} />BLOCK {block ? `#${block.toLocaleString("en-US")}` : "········"}
          </span>
          <span>{clock}</span>
          <ThemeToggle />
        </div>
      </header>

      <main>
        <section id="top" className="sec hero">
          <div className="wrap">
            <p className="kicker mono">SEC.00 / MINTMARK.SYS · {VERSION} · MEMECOIN LAUNCHPAD FOR ELYSIUM</p>
            <h1 className="mega brand-mega">Mint<br />Mark.</h1>
            <p className="sub">Mint a meme. <mark>Same forge. New orbit.</mark></p>
            <div className="desk hero-desk">
              <Win title="README.TXT" className="w-readme" meta="2 KB">
                <p>
                  MintMark is moving to Elysium. Explore token launches, a public bonding curve, and
                  graduation into DEX liquidity. The app below is a simulation with demo HYPE;
                  live trading awaits verified contracts and deployment.
                </p>
                <div className="btns">
                  <a className="btn default" href="/app">Launch app <span className="tag">DEMO</span></a>
                  <a className="btn" href="#zk">Why Elysium</a>
                </div>
              </Win>
              <Win title="Get Info: $FORGE" className="w-info">
                <dl className="kv mono">
                  <dt>KIND</dt><dd>ERC-20 · EVM</dd>
                  <dt>SUPPLY</dt><dd>1,000,000,000</dd>
                  <dt>LAUNCH</dt><dd>Demo available</dd>
                  <dt>LP</dt><dd>Locked forever at graduation</dd>
                  <dt>GAS</dt><dd>HYPE</dd>
                  <dt>STATUS</dt><dd>Pre-launch</dd>
                </dl>
              </Win>
            </div>
          </div>
        </section>

        <Marquee />

        <section id="cast" className="sec cast">
          <div className="wrap split">
            <div className="spacer" />
            <div>
              <p className="kicker mono">SEC.01 / CAST</p>
              <h2 className="mega-2">3 fields.<br />1 tx.</h2>
              <p className="lede">
                Name it, pick a ticker, add the image. Your meme is minted with a fixed supply of one billion and
                uses the same public curve. Try the flow with simulated balances before live deployment.
              </p>
              <Win title="New Token" className="w-dialog" meta="⌘N">
                <div className="fields">
                  <label><span className="px">NAME</span><div className="field">Forge</div></label>
                  <label><span className="px">TICKER</span><div className="field">$FORGE</div></label>
                  <label><span className="px">IMAGE</span><div className="field file"><span className="dither-thumb" />forge.png</div></label>
                  <label className="check"><span className="cb on" aria-hidden="true" /><span>Batch window <span className="tag">DEMO</span></span></label>
                </div>
                <div className="fee-row mono"><span>NETWORK FEE</span><span>≈ GAS ONLY</span></div>
                <div className="btns end">
                  <button className="btn" disabled>Cancel</button>
                  <button className="btn default" disabled>Mint it</button>
                </div>
              </Win>
            </div>
          </div>
        </section>

        <section id="curve" className="sec curve">
          <div className="sticky">
            <div className="wrap">
              <Win title="CURVE.MON" className="w-curve" meta="DEMO">
                <p className="kicker mono">SEC.02 / CLIMB</p>
                <h2>Price is math, not a mood.</h2>
                <p>
                  Every buy moves the meme up a public bonding curve. Everyone pays the curve price at the same point
                  on the curve. No allowlist, no insider round, no better deal behind the scenes.
                </p>
                <div className="readout mono">
                  <div><span className="k">SOLD</span><span ref={read.sold} className="v">0.0%</span></div>
                  <div><span className="k">PRICE HYPE</span><span ref={read.price} className="v">{formatTiny(curveAt(0).price)}</span></div>
                  <div><span className="k">NET HYPE</span><span ref={read.raised} className="v">0.000</span></div>
                </div>
                <div className="progress" aria-hidden="true">
                  <div ref={read.bar} />
                  <span ref={read.pct} className="mono">000%</span>
                </div>
                <p className="fine mono">f(x) = vHYPE ÷ vTOKEN · k = vHYPE × vTOKEN · illustrative</p>
              </Win>
            </div>
          </div>
        </section>

        <section id="graduate" className="sec graduate">
          <div className="wrap">
            <p className="kicker mono">SEC.03 / GRADUATE</p>
            <h2 className="mega-2">Locked in<br />for good.</h2>
            <div className="desk">
              <Win title="graduate.log" className="w-log" meta="tty0">
                <pre className="log mono">{`> curve.fill ............ 100%
> net liquidity ......... ${GRAD_RAISE.toFixed(0)} HYPE
> migrate(dex) .......... simulated
> lp.lock(forever) ...... simulated
> owner ................. none
> _`}</pre>
              </Win>
              <Win title="What happens" className="w-grad">
                <p>
                  At graduation, the contracts are designed to pair the net HYPE liquidity (after trading fees) with the remaining token supply
                  on a compatible DEX and lock the liquidity. The Elysium DEX configuration must be verified
                  before deployment. This page illustrates the flow; it does not move real funds.
                </p>
              </Win>
            </div>
          </div>
        </section>

        <section id="zk" className="sec zk">
          <div className="wrap">
            <p className="kicker mono">SEC.0x / ELYSIUM</p>
            <h2 className="mega-2">Built for<br />a new orbit.</h2>
            <div className="desk">
              <Win title="network.bin" className="w-proof" meta="SAMPLE">
                <pre className="hexdump mono">{PROOF.slice(2).match(/.{1,16}/g)!.map((row, i) =>
                  `${(i * 8).toString(16).padStart(4, "0")}  ${row.match(/.{2}/g)!.join(" ")}`).join("\n")}
{`\nnetwork .............. Elysium\ngas .................. HYPE\nstatus ............... pre-launch`}</pre>
              </Win>
              <Win title="Network.cfg" className="w-privacy">
                <ul className="features">
                  <li>
                    <span className="chip is-spec">CHAIN</span>
                    <div><b>Elysium, by Kinetiq.</b> An Arbitrum Orbit L2 settling to HyperEVM, with HYPE as native gas and standard EVM tooling.</div>
                  </li>
                  <li>
                    <span className="chip is-spec">SPEC</span>
                    <div><b>Batch-window demo.</b> The simulation collects orders and fills them at one clearing price. Orders are stored in the browser, not encrypted or zk-proven.</div>
                  </li>
                  <li>
                    <span className="chip is-spec">SPEC</span>
                    <div><b>Contracts before claims.</b> Live launchpad and DEX addresses must be deployed and verified on Elysium before real-money trading is enabled.</div>
                  </li>
                </ul>
                <p className="fine mono">Mainnet is pre-launch. The demo is not a privacy system and is not connected to a funded wallet.</p>
              </Win>
            </div>
          </div>
        </section>

        <section id="live" className="sec live">
          <div className="sticky">
            <div className="wrap">
              <Win title="About to graduate" className="w-list" meta="SAMPLE DATA">
                <p className="kicker mono">SEC.04 / DEMO</p>
                <h2>Who graduates next?</h2>
                <p className="small">
                  Each sample coin shows simulated bonding-curve progress. Cross the dotted line
                  to preview graduation. No live DEX pool is created in this demo. Hover a coin to read it.
                </p>
                <dl className="legend mono">
                  <dt><span className="lg-stem" /></dt><dd>Height = progress along the curve</dd>
                  <dt><span className="lg-dash" /></dt><dd>Graduation line · {GRAD_RAISE.toFixed(0)} HYPE net liquidity</dd>
                  <dt><span className="lg-coin">%</span></dt><dd>Stamp = ticker and curve %</dd>
                </dl>
              </Win>
            </div>
          </div>
        </section>

        <section id="fees" className="sec fees">
          <div className="wrap">
            <p className="kicker mono">SEC.05 / RULES</p>
            <h2 className="mega-2">No insiders.<br />No extraction.</h2>
            <Win title="FEES.TBL" className="w-fees" meta="DEMO ECONOMICS">
              <table className="rules">
                <tbody>
                  <tr><th>Launch a meme</th><td>Gas only</td></tr>
                  <tr><th>Trade on the curve</th><td>0.50% platform + 0–10% creator · chosen and locked at launch</td></tr>
                  <tr><th>Combined curve fee</th><td>0.50–10.50% · applies only before the curve closes</td></tr>
                  <tr><th>Sealed launch window</th><td>60 s demo batch · one clearing price · browser-stored orders, no privacy guarantee</td></tr>
                  <tr><th>Creator fees</th><td>Accrue per curve trade · claimable before or after graduation · saved recipient · no ongoing creator tax on ordinary V2 swaps</td></tr>
                  <tr><th>Rankings</th><td>By HYPE left in the curve, never volume · wash trades pay fees and move nothing</td></tr>
                  <tr><th>Graduation</th><td>{GRAD_RAISE.toFixed(0)} HYPE net liquidity · configured Elysium DEX pool at the final curve price · LP locked forever</td></tr>
                  <tr><th>Team allocation</th><td>None</td></tr>
                  <tr><th>Admin keys</th><td>See verified deployment permissions before trading</td></tr>
                  <tr><th>Contracts</th><td>Elysium deployment and verification pending</td></tr>
                </tbody>
              </table>
              <p className="fine mono">Demo claims credit play HYPE to the saved creator account. Live fees and recipient are fixed at launch; check the deployed configuration. No security audit has been performed; deployment and verification are pending.</p>
            </Win>
          </div>
        </section>

        <section id="forge" className="sec cta">
          <div className="wrap">
            <h2 className="mega cta-mega">Mint<br />the <span className="eth">HYPE.</span></h2>
            <Win title="Alert" className="w-alert">
              <div className="alert">
                <span className="alert-icon" aria-hidden="true">!</span>
                <p>MintMark is being prepared for Elysium. The demo is open now; live trading follows verified deployment and testing.</p>
              </div>
              <div className="btns end">
                <a className="btn default" href="/app">Try the demo <span className="tag">DEMO</span></a>
              </div>
            </Win>
          </div>
        </section>
      </main>

      <footer className="statusbar mono">
        <span>MintMark · {VERSION} · {HEX_NAME}</span>
        <span className="built">For Elysium · HYPE</span>
        <span>Memecoins are risky. Only use what you can afford to lose.</span>
      </footer>
    </>
  );
}
