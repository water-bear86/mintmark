import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { erc20Abi, formatEther, getAddress, type Address, type EIP1193Provider, type Hex } from "viem";
import type { DexRoute } from "../network/dexAbi";
import { parseHype, parseCreatorFeePercent, formatFeePercent } from "../network/amounts";
import { createElysiumLaunchpad, UncertainSubmissionError, TransactionReplacedError, isFinalSubmissionFailure } from "../network/client";
import { matchesSubmission, readRecovery, persistSubmissionIntent, persistPendingHash, clearRecoveryKey, type StoredSubmission } from "../network/submission";
import { elysium } from "../network/elysium";
import { launchpadAbi } from "../network/launchpadAbi";
import { useChainBlock } from "../ui/useChainBlock";
import { ThemeToggle } from "../ui/ThemeToggle";
import { Win } from "../ui/Win";

type Provider = EIP1193Provider & { on?: (event: string, fn: (...args: unknown[]) => void) => void; removeListener?: (event: string, fn: (...args: unknown[]) => void) => void };
type Client = ReturnType<typeof createElysiumLaunchpad>;
type Curve = Awaited<ReturnType<Client["curve"]>>;
const compact = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;
const errorText = (e: unknown) => e instanceof Error ? e.message.slice(0, 500) : "Request failed";
const address = import.meta.env.VITE_ELYSIUM_LAUNCHPAD_ADDRESS;
const pendingKey = `mintmark.pending.${elysium.id}.${address || "unconfigured"}`;
function savedUncertain(): StoredSubmission | null {
  try { return readRecovery(localStorage, sessionStorage, pendingKey).uncertain; }
  catch { return { legacy: true }; }
}
function savedHash(): Hex | null {
  try { return readRecovery(localStorage, sessionStorage, pendingKey).hash; } catch { return null; }
}

export function LiveApp() {
  const provider = useMemo(() => (window as Window & { ethereum?: Provider }).ethereum, []);
  const [uncertain, setUncertain] = useState<StoredSubmission | null>(savedUncertain);
  const setup = useMemo(() => {
    try { return { client: address ? createElysiumLaunchpad(elysium, address, provider, {
      onPrepared: intent => { persistSubmissionIntent(localStorage, sessionStorage, pendingKey, intent); setUncertain({ intent }); },
      onRejected: () => { clearRecoveryKey(localStorage, sessionStorage, `${pendingKey}.uncertain`); setUncertain(null); },
    }) : null, error: "" }; }
    catch (e) { return { client: null, error: errorText(e) }; }
  }, [provider]);
  const client = setup.client;
  const block = useChainBlock();
  const [account, setAccount] = useState<Address | null>(null);
  const [walletChain, setWalletChain] = useState<number | null>(null);
  const [tab, setTab] = useState<"discover" | "launch" | "fees">("discover");
  const [curves, setCurves] = useState<readonly Curve[]>([]);
  const [page, setPage] = useState(0n);
  const [total, setTotal] = useState(0n);
  const [token, setToken] = useState<Address | null>(null);
  const [amount, setAmount] = useState("0.1");
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [balance, setBalance] = useState("");
  const [fee, setFee] = useState<bigint | null>(null);
  const [graduationLiquidity, setGraduationLiquidity] = useState<bigint | null>(null);
  const [name, setName] = useState("");
  const [symbol, setSymbol] = useState("");
  const [uri, setUri] = useState("");
  const [creatorPercent, setCreatorPercent] = useState("0");
  const [feeToken, setFeeToken] = useState("");
  const [feeDetails, setFeeDetails] = useState<(Awaited<ReturnType<Client["creatorFees"]>> & { at: number }) | null>(null);
  const feeLookupVersion = useRef(0);
  let creatorBps: number | null = null;
  try { creatorBps = parseCreatorFeePercent(creatorPercent); } catch { /* Invalid input disables launch. */ }
  const [quote, setQuote] = useState<{ token: Address; side: "buy" | "sell"; input: bigint; output: bigint; min: bigint; at: number; route?: DexRoute; needsApproval: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const lock = useRef(false);
  const generation = useRef(0);
  const [notice, setNotice] = useState("");
  const [hash, setHash] = useState<Hex | null>(savedHash);
  const [pending, setPending] = useState(Boolean(savedHash()));
  const [reconcileHash, setReconcileHash] = useState("");
  const refreshVersion = useRef(0);
  const [verified, setVerified] = useState(false);
  const current = curves.find(c => c.token === token);
  const correctChain = walletChain === elysium.id;
  const writable = Boolean(client && verified && account && correctChain && !busy && !pending && !uncertain);

  const refresh = useCallback(async () => {
    if (!client) return;
    const version = ++refreshVersion.current;
    setVerified(false);
    await client.ready();
    const [rows, count, launchFee, virtualHype, virtualTokens, curveSupply] = await Promise.all([
      client.curves(page * 20n, 20n), client.tokensLength(), client.launchFee(),
      client.publicClient.readContract({ address: client.address, abi: launchpadAbi, functionName: "VIRTUAL_ETH_0" }),
      client.publicClient.readContract({ address: client.address, abi: launchpadAbi, functionName: "VIRTUAL_TOKENS_0" }),
      client.publicClient.readContract({ address: client.address, abi: launchpadAbi, functionName: "CURVE_SUPPLY" }),
    ]);
    if (virtualTokens <= curveSupply) throw new Error("Invalid onchain curve parameters");
    const remaining = virtualTokens - curveSupply;
    // Match the contract’s ceil division, including older deployed parameters.
    const netLiquidity = (virtualHype * virtualTokens + remaining - 1n) / remaining - virtualHype;
    if (version === refreshVersion.current) { setCurves(rows); setTotal(count); setFee(launchFee); setGraduationLiquidity(netLiquidity); setVerified(true); }
  }, [client, page]);
  useEffect(() => { setVerified(false); void refresh().catch(e => setNotice(errorText(e))); }, [refresh]);
  useEffect(() => {
    document.title = "MintMark · Elysium contracts";
    const changed = () => {
      generation.current++; feeLookupVersion.current++; setFeeDetails(null); setQuote(null); setAccount(null); setWalletChain(null); setBalance("");
      setNotice("Wallet changed or disconnected. Reconnect before continuing.");
    };
    provider?.on?.("accountsChanged", changed); provider?.on?.("chainChanged", changed); provider?.on?.("disconnect", changed);
    return () => {
      generation.current++;
      provider?.removeListener?.("accountsChanged", changed); provider?.removeListener?.("chainChanged", changed); provider?.removeListener?.("disconnect", changed);
    };
  }, [provider]);
  useEffect(() => { setQuote(null); }, [token, amount, side]);
  useEffect(() => {
    let active = true; setBalance("");
    if (client && account && token && verified) {
      void client.publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [account] })
        .then(v => { if (active) setBalance(formatEther(v)); }).catch(() => {});
    }
    return () => { active = false; };
  }, [client, account, token, verified, curves]);

  async function run(fn: () => Promise<void>) {
    if (lock.current) return;
    lock.current = true; setBusy(true); setNotice("");
    try { await fn(); } catch (e) {
      if (e instanceof UncertainSubmissionError && e.intent) setUncertain({ intent: e.intent });
      setNotice(errorText(e));
    }
    finally { lock.current = false; setBusy(false); }
  }
  async function connect() {
    if (!provider) throw new Error("Install an Ethereum-compatible wallet to continue.");
    const accounts = await provider.request({ method: "eth_requestAccounts" });
    const chain = await provider.request({ method: "eth_chainId" });
    setAccount(accounts[0] ? getAddress(accounts[0]) : null); setWalletChain(Number(BigInt(chain)));
    setNotice(Number(BigInt(chain)) === elysium.id ? "Wallet connected." : `Switch your wallet to ${elysium.name} (${elysium.id}), then reconnect.`);
  }
  async function getQuote() {
    if (!client || !token) throw new Error("Select a token first.");
    const epoch = generation.current;
    const input = parseHype(amount);
    if (input <= 0n) throw new Error("Enter a positive amount.");
    const curve = await client.curve(token);
    const dex = curve.graduated ? await client.quoteDex(token, input, side) : null;
    const output = dex ? dex.output : (side === "buy" ? await client.quoteBuy(token, input) : await client.quoteSell(token, input))[0];
    const needsApproval = Boolean(dex && side === "sell" && (!account || await client.dexAllowance(token, account, dex.route) < input));
    if (output * 99n / 100n <= 0n) throw new Error("This amount is too small for a protected minimum output.");
    if (epoch !== generation.current) return;
    setQuote({ token, side, input, output, min: output * 99n / 100n, at: Date.now(), route: dex?.route, needsApproval });
  }
  function clearUncertain() {
    setUncertain(null);
    try { clearRecoveryKey(localStorage, sessionStorage, `${pendingKey}.uncertain`); } catch {}
  }
  async function reconcile() {
    if (!client || !uncertain || !/^0x[0-9a-f]{64}$/i.test(reconcileHash)) throw new Error("Enter the transaction hash shown in your wallet.");
    if (!("intent" in uncertain)) throw new Error("Legacy submission has no nonce-bound intent. Hash reconciliation is unavailable; inspect wallet history manually.");
    await client.ready();
    const tx = await client.publicClient.getTransaction({ hash: reconcileHash as Hex });
    if (!matchesSubmission(uncertain.intent, elysium.id, tx)) throw new Error("Transaction does not match the exact pending nonce, sender, target, calldata and value. No lock was cleared.");
    recordPending(tx.hash); await confirm(tx.hash);
  }
  function recordPending(tx: Hex) {
    setHash(tx); setPending(true);
    try { persistPendingHash(localStorage, sessionStorage, pendingKey, tx); setUncertain(null); } catch { /* Keep the persisted intent if hash storage fails. */ }
  }
  async function confirm(tx: Hex) {
    if (!client) return;
    try {
      const receipt = await client.receipt(tx);
      setHash(receipt.transactionHash);
      setPending(false);
      try { clearRecoveryKey(localStorage, sessionStorage, pendingKey); } catch {}
      setNotice("Transaction confirmed."); await refresh();
    } catch (e) {
      if (isFinalSubmissionFailure(e)) {
        if (e instanceof TransactionReplacedError) setHash(e.replacementHash);
        setPending(false); try { clearRecoveryKey(localStorage, sessionStorage, pendingKey); } catch {}
      }
      throw new Error(`Confirmation check: ${errorText(e)}. Keep the transaction hash and check its status before retrying.`);
    }
  }
  async function approve() {
    if (pending || uncertain) throw new Error("Resolve the previous transaction before submitting another.");
    if (!client || !quote?.route || !quote.needsApproval || !account || !correctChain) throw new Error("Get a DEX sell quote first.");
    const request = quote; setQuote(null); setHash(null);
    const tx = await client.approveDex(account, request.token, request.input, request.route!);
    recordPending(tx); setNotice("Approval submitted. This does not sell your tokens.");
    await confirm(tx);
    setNotice("Exact sell amount approved. Get a fresh quote, then confirm the separate swap in your wallet.");
  }
  async function trade() {
    if (pending || uncertain) throw new Error("Resolve the previous transaction before submitting another.");
    if (!client || !quote || !account || !correctChain) throw new Error("Connect on Elysium and get a quote first.");
    if (Date.now() - quote.at > 60_000) { setQuote(null); throw new Error("Quote expired. Get a fresh quote."); }
    const request = quote; setQuote(null); setHash(null);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 120);
    if (request.needsApproval) throw new Error("Approve the exact amount, then get a fresh quote.");
    const tx = request.route ? await client.tradeDex(account, request.token, request.input, request.min, deadline, request.side, request.route) : request.side === "buy" ? await client.buy(account, request.token, request.input, request.min, deadline) : await client.sell(account, request.token, request.input, request.min, deadline);
    recordPending(tx); setNotice("Submitted. Waiting for onchain confirmation; do not resubmit.");
    await confirm(tx);
  }
  function selectFeeToken(value: string) {
    feeLookupVersion.current++; setFeeDetails(null); setFeeToken(value);
  }
  async function loadFees() {
    if (!client) return;
    const selected = getAddress(feeToken.trim());
    const version = ++feeLookupVersion.current;
    setFeeDetails(null);
    const details = await client.creatorFees(selected);
    if (version === feeLookupVersion.current) setFeeDetails({ ...details, at: Date.now() });
  }
  async function collectFees() {
    if (pending || uncertain) throw new Error("Resolve the previous transaction before submitting another.");
    if (!client || !account || !correctChain || !verified || !feeDetails) throw new Error("Connect on Elysium and refresh fees first.");
    if (Date.now() - feeDetails.at > 60_000 || feeDetails.token.toLowerCase() !== feeToken.trim().toLowerCase()) {
      setFeeDetails(null); throw new Error("Fee details expired. Refresh fees and review the recipient again.");
    }
    const reviewed = feeDetails; setFeeDetails(null); setHash(null);
    const tx = await client.collectCreatorFees(account, reviewed.token, reviewed.recipient);
    recordPending(tx); setNotice("Collection submitted. Fees go only to the stored recipient.");
    await confirm(tx);
    await loadFees();
  }
  async function launch() {
    if (pending || uncertain) throw new Error("Resolve the previous transaction before submitting another.");
    if (!client || !account || !correctChain || fee === null) throw new Error("Connect on Elysium first.");
    if (!name.trim() || !symbol.trim()) throw new Error("Name and ticker are required.");
    const bytes = (value: string) => new TextEncoder().encode(value.trim()).length;
    if (bytes(name) > 32 || bytes(symbol) > 10 || bytes(uri) > 256) throw new Error("Name must fit 32 UTF-8 bytes, ticker 10 bytes, and metadata URI 256 bytes.");
    if (uri && !/^(https:\/\/|ipfs:\/\/)/.test(uri)) throw new Error("Metadata URI must use HTTPS or IPFS.");
    setHash(null);
    const tx = await client.launch(account, { name: name.trim(), symbol: symbol.trim(), metadataURI: uri.trim(), creatorFeeBps: parseCreatorFeePercent(creatorPercent), plugin: account, minTokensOut: 0n, maxLaunchFee: fee, value: fee });
    recordPending(tx); setNotice("Launch submitted. Waiting for onchain confirmation; do not resubmit.");
    setName(""); setSymbol(""); setUri(""); setCreatorPercent("0");
    await confirm(tx); setTab("discover");
  }

  return <div className="app">
    <div className="grid-overlay" aria-hidden="true" />
    <header className="menubar">
      <a href="/" className="brand"><img src="/favicon.svg" alt="" width={18} height={18} /><span>MintMark</span></a>
      <nav aria-label="Live app"><button className="menu-btn" disabled={busy} onClick={() => setTab("discover")}>Discover</button><button className="menu-btn" disabled={busy} onClick={() => setTab("launch")}>Launch</button><button className="menu-btn" disabled={busy} onClick={() => setTab("fees")}>Fees</button><a href="/app">Demo</a></nav>
      <div className="status mono"><span className="hide-sm">{elysium.name} · {block ?? "offline"}</span><ThemeToggle />
        {account ? <button className="menu-btn" disabled={busy} onClick={() => { generation.current++; feeLookupVersion.current++; setFeeDetails(null); setAccount(null); setQuote(null); setBalance(""); setNotice("Disconnected from this app. Wallet permissions remain in your wallet."); }}>{compact(account)} · Disconnect</button>
          : <button className="menu-btn" disabled={busy || !client} onClick={() => void run(connect)}>Connect wallet</button>}
      </div>
    </header>
    <main className="desk-app">
      <p className="kicker mono">ONCHAIN · {elysium.name} · HYPE · {elysium.id}</p>
      {!client ? <Win title="Deployment pending"><p>{setup.error || "No verified Elysium launchpad is configured. Live actions are disabled until deployment is complete."}</p><a className="btn" href="/app">Try the separate demo</a></Win> : <>
        <Win title="Connection"><p className="mono small-note">Launchpad: {client.address}</p><p>{verified ? "Connected to the configured Elysium contract." : "Checking RPC and deployment…"} {elysium.testnet ? "Testnet HYPE only." : "Mainnet transactions use real HYPE."}</p>
          {account && !correctChain && <p role="alert">Wrong wallet network. Select {elysium.name} ({elysium.id}) in your wallet, then reconnect.</p>}
          <button className="btn" disabled={busy} onClick={() => void run(refresh)}>Refresh contracts</button>
        </Win>
        {tab === "discover" ? <div className="live-grid">
          <Win title="Discover" meta="ONCHAIN">
            <p className="small-note">{total.toString()} tokens. Live addresses and curve state only; no simulated rankings or prices.</p>
            <div className="table-wrap"><table className="lens-table"><thead><tr><th>TOKEN</th><th>SOLD</th><th>STATUS</th></tr></thead><tbody>
              {curves.map(c => <tr key={c.token}><td><button className="menu-btn" disabled={busy} onClick={() => { setToken(c.token); setQuote(null); }}>{compact(c.token)}</button></td><td>{Number(formatEther(c.tokensSold)).toLocaleString()}</td><td>{c.graduated ? "Graduated" : "Curve"}</td></tr>)}
            </tbody></table></div>
            {!curves.length && <p>No launches on this page.</p>}
            <div className="btns" style={{ marginTop: 24 }}><button className="btn" disabled={busy || page === 0n} onClick={() => { setPage(p => p - 1n); setToken(null); }}>Previous</button><button className="btn" disabled={busy || (page + 1n) * 20n >= total} onClick={() => { setPage(p => p + 1n); setToken(null); }}>Next</button></div>
          </Win>
          <Win title="Trade" meta="WALLET SIGNED">
            {!current ? <p>Select a token to trade.</p> : <>
              <p className="mono live-address">{current.token}</p>
              {current.graduated && <p>Graduated · trades use the launchpad’s verified V2 pool. Pending migrations cannot trade yet.</p>}
              <button className="btn" disabled={busy} onClick={() => { selectFeeToken(current.token); setTab("fees"); }}>View creator fees</button>
              <>
                <div className="seg full"><button disabled={busy} className={side === "buy" ? "on" : ""} onClick={() => setSide("buy")}>Buy</button><button disabled={busy} className={side === "sell" ? "on" : ""} onClick={() => setSide("sell")}>Sell</button></div>
                <label className="live-label">{side === "buy" ? "HYPE to spend" : "Tokens to sell"}<input className="field mono" disabled={busy} value={amount} inputMode="decimal" onChange={e => setAmount(e.target.value)} /></label>
                {balance && <p className="small-note">Wallet token balance: {balance}</p>}
                <button className="btn" disabled={busy || !verified} onClick={() => void run(getQuote)}>Get quote</button>
                {quote && <div className="result"><p>Expected: {formatEther(quote.output)} {side === "buy" ? "tokens" : "HYPE"}</p><p>Minimum: {formatEther(quote.min)} · 1% slippage · quote expires after 60 seconds.</p>{quote.route && <p className="small-note mono">DEX router: {quote.route.router}</p>}{quote.needsApproval ? <><p>Approve exactly {formatEther(quote.input)} tokens for this router. Approval is a separate transaction; refresh the quote afterward.</p><button className="btn default" disabled={!writable} onClick={() => void run(approve)}>Approve exact sell amount</button></> : <button className="btn default" disabled={!writable} onClick={() => void run(trade)}>Confirm {side} in wallet</button>}</div>}
              </>
            </>}
          </Win>
        </div> : tab === "fees" ? <Win title="Creator fees" meta="ONCHAIN">
          <p>Look up any token from this launchpad, including tokens beyond the current discovery page.</p>
          <label className="live-label">Token address<input className="field mono" disabled={busy} value={feeToken} onChange={e => selectFeeToken(e.target.value)} placeholder="0x…" /></label>
          <button className="btn" disabled={busy || !verified || !feeToken.trim()} onClick={() => void run(loadFees)}>Refresh fees</button>
          {busy && <p role="status">Checking fee transaction or loading onchain details…</p>}
          {!feeDetails && !busy && <p>Enter a token address and refresh to review its fees and recipient.</p>}
          {feeDetails && <div className="result">
            <p>Pending: {formatEther(feeDetails.pending)} HYPE</p>
            <p className="small-note mono">Exact amount: {feeDetails.pending.toString()} wei · block {feeDetails.blockNumber.toString()}</p>
            <p>Creator fee: {formatFeePercent(feeDetails.creatorFeeBps)}% · platform: 0.50% · combined curve fee: {formatFeePercent(feeDetails.creatorFeeBps + 50)}%</p>
            <p>Stored immutable recipient:</p><p className="mono live-address">{feeDetails.recipient}</p>
            <p>Anyone may collect, but funds always go to this stored recipient, never automatically to the caller. A contract recipient may require its own withdrawal process.</p>
            <p>Creator fees accrue only on the bonding curve. After graduation, normal V2 swaps have no creator tax; previously accrued fees remain collectible.</p>
            {feeDetails.pending === 0n && <p>No creator fees to collect.</p>}
            <button className="btn default" disabled={!writable || feeDetails.pending <= 0n} onClick={() => void run(collectFees)}>Collect to recipient</button>
          </div>}
        </Win> : <Win title="Launch a meme" meta="ONCHAIN">
          <p>Fixed supply: 1 billion tokens. No initial buy. No private batch window.</p>
          <p>Fresh-curve graduation net liquidity target: {verified && graduationLiquidity !== null ? `${formatEther(graduationLiquidity)} HYPE` : "loading from contract…"}. Excludes trading fees; this is not gross spend or market cap. Multiple trades may add wei through rounding.</p>
          <fieldset className="live-form" disabled={!writable}>
            <label>Name<input className="field" maxLength={32} value={name} onChange={e => setName(e.target.value)} /></label>
            <label>Ticker<input className="field" maxLength={10} value={symbol} onChange={e => setSymbol(e.target.value)} /></label>
            <label>Metadata URI (optional)<input className="field" maxLength={256} value={uri} onChange={e => setUri(e.target.value)} placeholder="ipfs://… or https://…" /></label>
            <label>Creator fee (%)<input className="field mono" inputMode="decimal" value={creatorPercent} onChange={e => setCreatorPercent(e.target.value)} aria-describedby="creator-fee-help" /></label>
            <p id="creator-fee-help">Choose 0%–10% in 0.01% increments. Default: 0%. This rate is immutable after launch.</p>
            {creatorBps === null ? <p role="alert">Enter a percentage from 0 to 10 with at most two decimal places.</p> : <p>Curve trading fees: 0.50% platform + {formatFeePercent(creatorBps)}% creator = {formatFeePercent(creatorBps + 50)}% total.</p>}
            <p>Creator fees go to your connected wallet, fixed at launch:</p><p className="mono live-address">{account || "Connect wallet first"}</p>
            <p>Applies only on the bonding curve. After graduation, normal V2 swaps have no creator tax. Collect accrued fees from the Fees tab.</p>
            <p>Launch fee: {fee === null ? "loading" : `${formatEther(fee)} HYPE`} plus network gas. Fee cap is enforced onchain.</p>
            <button className="btn default" disabled={!name.trim() || !symbol.trim() || creatorBps === null} onClick={() => void run(launch)}>Review launch in wallet</button>
          </fieldset>
        </Win>}
      </>}
      {uncertain && <div className="result" role="alert"><p>Wallet submission outcome is unknown. It may have been broadcast. New transactions are disabled. Check activity for {"intent" in uncertain ? compact(uncertain.intent.from) : "the original submitting account"} in your wallet before continuing.</p>{!("intent" in uncertain) && <p>This older record has no transaction nonce or calldata. Automatic hash reconciliation is disabled; inspect the original wallet activity manually.</p>}<label>Submitted transaction hash<input className="field mono" value={reconcileHash} onChange={e => setReconcileHash(e.target.value.trim())} /></label><button className="btn" disabled={busy || !client || !("intent" in uncertain)} onClick={() => void run(reconcile)}>Check this transaction</button><button className="btn" disabled={busy} onClick={() => { if (window.confirm("Only continue if you checked your wallet and confirmed that no transaction was submitted. An unchecked retry could duplicate your transaction.")) { clearUncertain(); setNotice("You confirmed that no transaction was submitted. You may start again."); } }}>I verified nothing was submitted</button></div>}
      {pending && hash && <div className="result"><p>A transaction is awaiting confirmed status. Further submissions are disabled.</p><button className="btn" disabled={busy || !client} onClick={() => void run(() => confirm(hash))}>Check transaction status</button></div>}
      {(notice || busy || hash) && <div className="result" role="status" aria-live="polite"><p>{busy ? "Working… " : ""}{notice}</p>{hash && <p className="mono live-address">Transaction: {hash}</p>}</div>}
    </main>
    <footer className="statusbar mono"><span>{elysium.testnet ? "ELYSIUM TESTNET" : "ELYSIUM MAINNET"} · Onchain mode · No simulated balances</span><span>For Elysium · HYPE</span></footer>
  </div>;
}
