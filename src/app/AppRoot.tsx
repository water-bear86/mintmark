import { useChainBlock } from "../ui/useChainBlock";
import { elysium } from "../network/elysium";
import { useEffect, useRef, useState } from "react";
import "./app.css";
import { Link, usePath } from "../ui/router";
import { ThemeToggle } from "../ui/ThemeToggle";
import { useMarket, connectDemo, disconnect, refill, short, fmtEth, HYPE_USD } from "./market";
import { Discover } from "./Discover";
import { TokenPage } from "./TokenPage";
import { Launch } from "./Launch";
import { LiveApp } from "./LiveApp";


function WalletChip() {
  const wallet = useMarket((s) => s.wallet && { ...s.wallet });
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const close = (e: PointerEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    addEventListener("pointerdown", close);
    return () => removeEventListener("pointerdown", close);
  }, []);
  if (!wallet) return <button className="menu-btn" onClick={connectDemo}>Connect <span className="tag">DEMO</span></button>;
  return (
    <div className="wallet" ref={ref}>
      <button className={`menu-btn ${open ? "on" : ""}`} onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        <span className="mono">{short(wallet.address)}</span> <span className="mono">{fmtEth(wallet.eth)}</span>
      </button>
      {open && (
        <div className="menu-drop" role="menu">
          <div className="menu-head mono">DEMO WALLET · play HYPE, not real</div>
          <button role="menuitem" onClick={() => { refill(); setOpen(false); }}>Add 1 demo HYPE</button>
          <Link role="menuitem" to="/app?lens=mine" onClick={() => setOpen(false)}>My memes</Link>
          <hr />
          <button role="menuitem" onClick={() => { disconnect(); setOpen(false); }}>Disconnect</button>
        </div>
      )}
    </div>
  );
}

function DemoApp() {
  const path = usePath();
  const block = useChainBlock();
  const tokenId = path.match(/^\/app\/t\/([^/]+)/)?.[1];
  const page = path.startsWith("/app/launch") ? "launch" : tokenId ? "token" : "discover";

  useEffect(() => {
    document.title = page === "launch" ? "Launch a meme · MintMark" : page === "token" ? "MintMark" : "Discover · MintMark";
  }, [page]);

  return (
    <div className="app">
      <div className="grid-overlay" aria-hidden="true" />
      <header className="menubar">
        <a href="/" className="brand" aria-label="MintMark home">
          <img src="/favicon.svg" alt="" width={18} height={18} />
          <span>MintMark</span>
        </a>
        <nav aria-label="App">
          <Link to="/app" className={page === "discover" ? "active" : ""}>Discover</Link>
          <Link to="/app/launch" className={page === "launch" ? "active" : ""}>Launch</Link>
          <a href="/app/live">Onchain</a>
        </nav>
        <div className="status mono">
          <span className="hide-sm" title={`Latest verified ${elysium.name} block`}>
            <i className={`led ${block ? "on" : ""}`} />BLOCK {block ? `#${block.toLocaleString("en-US")}` : "········"}
          </span>
          <ThemeToggle />
          <WalletChip />
        </div>
      </header>

      <main className="desk-app">
        {page === "discover" && <Discover />}
        {page === "token" && <TokenPage id={tokenId!} />}
        {page === "launch" && <Launch />}
      </main>

      <footer className="statusbar mono">
        <span><b className="demo-flag">DEMO MARKET</b> Simulated traders and prices. USD uses a fictional ${HYPE_USD.toLocaleString()}/HYPE rate. No real money.</span>
        <span className="built">For Elysium · HYPE</span>
      </footer>
    </div>
  );
}

export default function AppRoot() {
  const path = usePath();
  return path.startsWith("/app/live") ? <LiveApp /> : <DemoApp />;
}
