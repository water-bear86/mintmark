import { erc20Abi, createPublicClient, createWalletClient, custom, defineChain, encodeFunctionData, getAddress, http, type Address, type EIP1193Provider, type Hex } from "viem";
import { dexAbi, type DexRoute } from "./dexAbi";
import { launchpadAbi } from "./launchpadAbi";
import type { SubmissionIntent } from "./submission";
import type { ElysiumNetwork } from "./elysium";

/** A wallet/provider failure after requesting a send does not prove that nothing was broadcast. */
export class UncertainSubmissionError extends Error {
  readonly intent?: SubmissionIntent;
  constructor(cause: unknown, intent?: SubmissionIntent) {
    super("Submission outcome unknown. Check wallet activity before sending another transaction.", { cause });
    this.name = "UncertainSubmissionError";
    this.intent = intent;
  }
}
export class TransactionReplacedError extends Error {
  readonly replacementHash: Hex;
  constructor(reason: string, replacementHash: Hex) {
    super(`Original transaction was ${reason}; it did not confirm the requested action.`);
    this.name = "TransactionReplacedError";
    this.replacementHash = replacementHash;
  }
}
/** Only a mined receipt with status=reverted proves this submission failed onchain. */
export class TransactionRevertedError extends Error {
  constructor() {
    super("Transaction reverted");
    this.name = "TransactionRevertedError";
  }
}
/** Provider messages cannot prove finality, regardless of their wording. */
export function isFinalSubmissionFailure(error: unknown): boolean {
  return error instanceof TransactionReplacedError || error instanceof TransactionRevertedError;
}
function userRejected(error: unknown): boolean {
  const seen = new Set<unknown>();
  let current = error;
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current);
    const item = current as { code?: unknown; name?: unknown; cause?: unknown };
    if (item.code === 4001 || item.name === "UserRejectedRequestError") return true;
    current = item.cause;
  }
  return false;
}
export async function submitWalletTransaction(send: () => Promise<Hex>, intent?: SubmissionIntent, onRejected?: () => void): Promise<Hex> {
  try { return await send(); }
  catch (error) {
    if (userRejected(error)) { onRejected?.(); throw error; }
    // Conservative: arbitrary provider errors (including disconnects) can follow a broadcast.
    throw new UncertainSubmissionError(error, intent);
  }
}

export type LaunchRequest = { name: string; symbol: string; metadataURI: string; creatorFeeBps: number; plugin: Address; pluginData?: Hex; minTokensOut: bigint; maxLaunchFee: bigint; value: bigint };
/** Explicitly constructed live client. Never falls back to demo balances or signs on a server. */
export function createElysiumLaunchpad(network: ElysiumNetwork, launchpad: string, provider?: EIP1193Provider, lifecycle?: { onPrepared: (intent: SubmissionIntent) => void; onRejected: () => void }) {
  if (network.id !== 99801 && network.id !== 99901) throw new Error("Unsupported Elysium chain");
  if (!network.rpcUrl) throw new Error("Elysium RPC is not configured");
  const address = getAddress(launchpad);
  if (address === "0x0000000000000000000000000000000000000000") throw new Error("Launchpad is not deployed");
  const chain = defineChain({ id: network.id, name: network.name, nativeCurrency: network.nativeCurrency, rpcUrls: { default: { http: [network.rpcUrl] } }, testnet: network.testnet });
  const publicClient = createPublicClient({ chain, transport: http(network.rpcUrl) });
  const walletClient = provider ? createWalletClient({ chain, transport: custom(provider) }) : null;
  async function ready() {
    if (await publicClient.getChainId() !== chain.id) throw new Error("RPC chain mismatch");
    const code = await publicClient.getCode({ address });
    if (!code || code === "0x") throw new Error("No launchpad contract at configured address");
  }
  async function account(expectedAccount: Address) {
    // The caller captures the reviewed UI account before any RPC await. Never adopt a newly selected signer.
    if (!expectedAccount) throw new Error("Expected wallet account is required");
    const expected = getAddress(expectedAccount);
    await ready();
    if (!walletClient) throw new Error("Wallet required");
    if (await walletClient.getChainId() !== chain.id) throw new Error(`Switch wallet to ${network.name}`);
    const [signer] = await walletClient.getAddresses();
    if (!signer) throw new Error("Connect wallet first");
    if (!same(signer, expected)) throw new Error("Wallet account changed; review the transaction again");
    return signer;
  }
  async function prepareAndSend(signer: Address, data: Hex, value: bigint, send: (nonce: number) => Promise<Hex>, target: Address = address) {
    const nonce = await publicClient.getTransactionCount({ address: signer, blockTag: "pending" });
    if (!Number.isSafeInteger(nonce) || nonce < 0) throw new Error("Invalid transaction nonce");
    if (await account(signer) !== signer) throw new Error("Wallet account changed; review the transaction again");
    const intent: SubmissionIntent = { version: 1, chainId: network.id, from: signer, to: target, nonce, data, value: value.toString() };
    // Persistence must succeed BEFORE eth_sendTransaction. A reload during wallet confirmation stays locked.
    lifecycle?.onPrepared(intent);
    return submitWalletTransaction(() => send(nonce), intent, lifecycle?.onRejected);
  }
  async function read(functionName: "launchFee" | "tokensLength") {
    await ready();
    return publicClient.readContract({ address, abi: launchpadAbi, functionName });
  }
  const same = (a: Address, b: Address) => a.toLowerCase() === b.toLowerCase();
  async function contract(target: Address) {
    const code = await publicClient.getCode({ address: target });
    if (/^0x0{40}$/i.test(target) || !code || code === "0x") throw new Error("DEX contract is unavailable; migration may still be pending");
  }
  async function dexRoute(token: Address): Promise<DexRoute> {
    await ready();
    const curve = await publicClient.readContract({ address, abi: launchpadAbi, functionName: "curves", args: [token] });
    if (!curve.graduated || !same(curve.token, token)) throw new Error("Token has not graduated from this launchpad");
    const migrator = await publicClient.readContract({ address, abi: launchpadAbi, functionName: "migrator" });
    await contract(migrator); await contract(token);
    const [router, factory, wrapped, predicted] = await Promise.all([
      publicClient.readContract({ address: migrator, abi: dexAbi, functionName: "router" }),
      publicClient.readContract({ address: migrator, abi: dexAbi, functionName: "dexFactory" }),
      publicClient.readContract({ address: migrator, abi: dexAbi, functionName: "weth" }),
      publicClient.readContract({ address: migrator, abi: dexAbi, functionName: "poolFor", args: [token] }),
    ]);
    await Promise.all([contract(router), contract(factory), contract(wrapped), contract(curve.pool)]);
    const [routerFactory, routerWrapped, pair, tokenPool, owner, unlocked, t0, t1, reserves, pairFactory] = await Promise.all([
      publicClient.readContract({ address: router, abi: dexAbi, functionName: "factory" }),
      publicClient.readContract({ address: router, abi: dexAbi, functionName: "WETH" }),
      publicClient.readContract({ address: factory, abi: dexAbi, functionName: "getPair", args: [token, wrapped] }),
      publicClient.readContract({ address: token, abi: dexAbi, functionName: "pool" }),
      publicClient.readContract({ address: token, abi: dexAbi, functionName: "launchpad" }),
      publicClient.readContract({ address: token, abi: dexAbi, functionName: "poolUnlocked" }),
      publicClient.readContract({ address: curve.pool, abi: dexAbi, functionName: "token0" }),
      publicClient.readContract({ address: curve.pool, abi: dexAbi, functionName: "token1" }),
      publicClient.readContract({ address: curve.pool, abi: dexAbi, functionName: "getReserves" }),
      publicClient.readContract({ address: curve.pool, abi: dexAbi, functionName: "factory" }),
    ]);
    if (!same(routerFactory, factory) || !same(pairFactory, factory) || !same(routerWrapped, wrapped)
      || !same(pair, curve.pool) || !same(predicted, pair) || !same(tokenPool, pair) || !same(owner, address)
      || !((same(t0, token) && same(t1, wrapped)) || (same(t1, token) && same(t0, wrapped)))) throw new Error("DEX route does not match the launchpad migration configuration");
    if (!unlocked || reserves[0] === 0n || reserves[1] === 0n) throw new Error("Graduation liquidity is not ready; migration may still be pending");
    return { router, factory, wrapped, pool: pair };
  }
  async function checkedRoute(token: Address, expected: DexRoute) {
    const route = await dexRoute(token);
    if (!same(route.router, expected.router) || !same(route.pool, expected.pool) || !same(route.wrapped, expected.wrapped) || !same(route.factory, expected.factory)) throw new Error("DEX route changed; get a fresh quote");
    return route;
  }
  function tradeLimits(input: bigint, minimum: bigint, deadline: bigint) {
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (input <= 0n || minimum <= 0n || deadline <= now || deadline > now + 300n) throw new Error("Positive input/minimum and a deadline within five minutes are required");
  }
  return {
    network, address, ready, publicClient, dexRoute,
    async quoteDex(token: Address, input: bigint, side: "buy" | "sell") {
      if (input <= 0n) throw new Error("Enter a positive amount");
      const route = await dexRoute(token);
      const path = side === "buy" ? [route.wrapped, token] : [token, route.wrapped];
      const amounts = await publicClient.readContract({ address: route.router, abi: dexAbi, functionName: "getAmountsOut", args: [input, path] });
      if (amounts.length !== 2 || amounts[0] !== input || amounts[1] <= 0n) throw new Error("Invalid DEX quote");
      return { route, output: amounts[1] };
    },
    async dexAllowance(token: Address, owner: Address, expected: DexRoute) {
      const route = await checkedRoute(token, expected);
      return publicClient.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, route.router] });
    },
    async approveDex(expectedAccount: Address, token: Address, amount: bigint, expected: DexRoute) {
      if (amount <= 0n) throw new Error("Approval must be for a positive exact amount");
      const signer = await account(expectedAccount);
      const route = await checkedRoute(token, expected);
      const { request } = await publicClient.simulateContract({ address: token, abi: erc20Abi, functionName: "approve", args: [route.router, amount], account: signer });
      return prepareAndSend(signer, encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: request.args }), 0n, nonce => walletClient!.writeContract({ ...request, nonce }), token);
    },
    async tradeDex(expectedAccount: Address, token: Address, input: bigint, minimum: bigint, deadline: bigint, side: "buy" | "sell", expected: DexRoute) {
      tradeLimits(input, minimum, deadline);
      const signer = await account(expectedAccount);
      const route = await checkedRoute(token, expected);
      const path = side === "buy" ? [route.wrapped, token] : [token, route.wrapped];
      if (side === "sell") {
        const allowance = await publicClient.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [signer, route.router] });
        if (allowance < input) throw new Error("Approve the exact sell amount first, then get a fresh quote");
        const { request } = await publicClient.simulateContract({ address: route.router, abi: dexAbi, functionName: "swapExactTokensForETHSupportingFeeOnTransferTokens", args: [input, minimum, path, signer, deadline], account: signer });
        tradeLimits(input, minimum, deadline);
        return prepareAndSend(signer, encodeFunctionData({ abi: dexAbi, functionName: "swapExactTokensForETHSupportingFeeOnTransferTokens", args: request.args }), 0n, nonce => walletClient!.writeContract({ ...request, nonce }), route.router);
      }
      const { request } = await publicClient.simulateContract({ address: route.router, abi: dexAbi, functionName: "swapExactETHForTokensSupportingFeeOnTransferTokens", args: [minimum, path, signer, deadline], account: signer, value: input });
      tradeLimits(input, minimum, deadline);
      return prepareAndSend(signer, encodeFunctionData({ abi: dexAbi, functionName: "swapExactETHForTokensSupportingFeeOnTransferTokens", args: request.args }), input, nonce => walletClient!.writeContract({ ...request, nonce }), route.router);
    },
    launchFee: () => read("launchFee"),
    tokensLength: () => read("tokensLength"),
    async tokenAt(index: bigint) { await ready(); return publicClient.readContract({ address, abi: launchpadAbi, functionName: "tokenAt", args: [index] }); },
    async curve(token: Address) { await ready(); return publicClient.readContract({ address, abi: launchpadAbi, functionName: "curves", args: [token] }); },
    async curves(start = 0n, count = 50n) { await ready(); if (count < 1n || count > 100n) throw new Error("Page size must be 1..100"); return publicClient.readContract({ address, abi: launchpadAbi, functionName: "curvesPage", args: [start, count] }); },
    async quoteBuy(token: Address, value: bigint) { await ready(); return publicClient.readContract({ address, abi: launchpadAbi, functionName: "quoteBuy", args: [token, value] }); },
    async quoteSell(token: Address, tokens: bigint) { await ready(); return publicClient.readContract({ address, abi: launchpadAbi, functionName: "quoteSell", args: [token, tokens] }); },
    async creatorFees(token: Address) {
      await ready();
      // One block prevents mixing the displayed destination and pending balance across reads.
      const blockNumber = await publicClient.getBlockNumber();
      const [curve, pending] = await Promise.all([
        publicClient.readContract({ address, abi: launchpadAbi, functionName: "curves", args: [token], blockNumber }),
        publicClient.readContract({ address, abi: launchpadAbi, functionName: "pendingCreatorFees", args: [token], blockNumber }),
      ]);
      if (!same(curve.token, token) || /^0x0{40}$/i.test(curve.plugin)) throw new Error("Unknown token on this launchpad");
      return { token, recipient: curve.plugin, creatorFeeBps: curve.creatorFeeBps, pending, graduated: curve.graduated, blockNumber };
    },
    async collectCreatorFees(expectedAccount: Address, token: Address, expectedRecipient: Address) {
      const signer = await account(expectedAccount);
      const curve = await publicClient.readContract({ address, abi: launchpadAbi, functionName: "curves", args: [token] });
      if (!same(curve.token, token) || /^0x0{40}$/i.test(curve.plugin)) throw new Error("Unknown token on this launchpad");
      if (!same(curve.plugin, expectedRecipient)) throw new Error("Fee recipient changed; refresh and review again");
      const pending = await publicClient.readContract({ address, abi: launchpadAbi, functionName: "pendingCreatorFees", args: [token] });
      if (pending <= 0n) throw new Error("No creator fees to collect; refresh the balance");
      const { request } = await publicClient.simulateContract({ address, abi: launchpadAbi, functionName: "collectCreatorFees", args: [token], account: signer });
      return prepareAndSend(signer, encodeFunctionData({ abi: launchpadAbi, functionName: "collectCreatorFees", args: request.args }), 0n, nonce => walletClient!.writeContract({ ...request, nonce }));
    },
    async launch(expectedAccount: Address, input: LaunchRequest) {
      if (!Number.isInteger(input.creatorFeeBps) || input.creatorFeeBps < 0 || input.creatorFeeBps > 1000) throw new Error("Creator fee must be 0..1000 whole basis points");
      const recipient = getAddress(input.plugin);
      if (/^0x0{40}$/i.test(recipient) || /^0x0{36}dead$/i.test(recipient) || same(recipient, address)) throw new Error("Invalid creator fee recipient");
      const signer = await account(expectedAccount);
      const { request } = await publicClient.simulateContract({ address, abi: launchpadAbi, functionName: "createToken", args: [input.name, input.symbol, input.metadataURI, input.creatorFeeBps, input.plugin, input.pluginData ?? "0x", input.minTokensOut, input.maxLaunchFee], account: signer, value: input.value });
      if (await account(signer) !== signer) throw new Error("Wallet account changed; review the transaction again");
      return prepareAndSend(signer, encodeFunctionData({ abi: launchpadAbi, functionName: "createToken", args: request.args }), input.value, nonce => walletClient!.writeContract({ ...request, nonce }));
    },
    async buy(expectedAccount: Address, token: Address, value: bigint, minTokensOut: bigint, deadline: bigint) {
      const signer = await account(expectedAccount);
      const { request } = await publicClient.simulateContract({ address, abi: launchpadAbi, functionName: "buy", args: [token, minTokensOut, signer, deadline], account: signer, value });
      if (await account(signer) !== signer) throw new Error("Wallet account changed; review the transaction again");
      return prepareAndSend(signer, encodeFunctionData({ abi: launchpadAbi, functionName: "buy", args: request.args }), value, nonce => walletClient!.writeContract({ ...request, nonce }));
    },
    async sell(expectedAccount: Address, token: Address, tokens: bigint, minHypeOut: bigint, deadline: bigint) {
      const signer = await account(expectedAccount);
      const { request } = await publicClient.simulateContract({ address, abi: launchpadAbi, functionName: "sell", args: [token, tokens, minHypeOut, signer, deadline], account: signer });
      if (await account(signer) !== signer) throw new Error("Wallet account changed; review the transaction again");
      return prepareAndSend(signer, encodeFunctionData({ abi: launchpadAbi, functionName: "sell", args: request.args }), 0n, nonce => walletClient!.writeContract({ ...request, nonce }));
    },
    async receipt(hash: Hex) {
      await ready();
      let replacement: { reason: string; hash: Hex } | undefined;
      const receipt = await publicClient.waitForTransactionReceipt({ hash, onReplaced: (event) => {
        const sameCall = event.transaction.to?.toLowerCase() === event.replacedTransaction.to?.toLowerCase()
          && event.transaction.input === event.replacedTransaction.input
          && event.transaction.value === event.replacedTransaction.value;
        if (event.reason !== "repriced" || !sameCall) replacement = { reason: event.reason === "repriced" ? "replaced" : event.reason, hash: event.transactionReceipt.transactionHash };
      } });
      if (replacement) throw new TransactionReplacedError(replacement.reason, replacement.hash);
      if (receipt.status === "reverted") throw new TransactionRevertedError();
      if (receipt.status !== "success") throw new Error("Unrecognized receipt status; check again before retrying");
      return receipt;
    },
  };
}
