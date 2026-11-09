/** Kinetiq Elysium (not the unrelated ELY chain 1339).
 * Source: https://elysium.kinetiq.xyz/docs/connecting-to-elysium (2026-11-07).
 * Mainnet community endpoints are opt-in via config/elysium-mainnet.env.example; no provider is silently selected.
 */
export type ElysiumNetwork = {
  id: 99801 | 99901;
  name: string;
  nativeCurrency: { name: string; symbol: string; decimals: 18 };
  rpcUrl: string | null;
  explorerUrl: string | null;
  testnet: boolean;
};
const nativeCurrency = { name: "HYPE", symbol: "HYPE", decimals: 18 as const };
export const ELYSIUM_TESTNET: ElysiumNetwork = {
  id: 99801, name: "Elysium Testnet", nativeCurrency,
  rpcUrl: "https://testnet-rpc.elysium.kinetiq.xyz",
  explorerUrl: "https://elysium.kinetiq.xyz/testnet-explorer", testnet: true,
};
export const ELYSIUM_MAINNET: ElysiumNetwork = {
  id: 99901, name: "Elysium", nativeCurrency, rpcUrl: null, explorerUrl: null, testnet: false,
};
function publicUrl(value: string | undefined): string | null {
  if (!value?.trim()) return null;
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password) throw new Error("Elysium public endpoints must use HTTPS without credentials");
  return url.href.replace(/\/$/, "");
}
const selection = import.meta.env.VITE_ELYSIUM_NETWORK || "testnet";
if (selection !== "mainnet" && selection !== "testnet") throw new Error("VITE_ELYSIUM_NETWORK must be testnet or mainnet");
export const elysium: ElysiumNetwork = {
  ...(selection === "mainnet" ? ELYSIUM_MAINNET : ELYSIUM_TESTNET),
  ...(import.meta.env.VITE_ELYSIUM_RPC_URL ? { rpcUrl: publicUrl(import.meta.env.VITE_ELYSIUM_RPC_URL) } : {}),
  ...(import.meta.env.VITE_ELYSIUM_EXPLORER_URL ? { explorerUrl: publicUrl(import.meta.env.VITE_ELYSIUM_EXPLORER_URL) } : {}),
};
export async function elysiumRpc<T>(method: string, params: unknown[] = [], signal?: AbortSignal): Promise<T> {
  if (!elysium.rpcUrl) throw new Error("Elysium RPC is not configured");
  const response = await fetch(elysium.rpcUrl, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal });
  if (!response.ok) throw new Error(`Elysium RPC HTTP ${response.status}`);
  const data = await response.json();
  if (data.error || !("result" in data)) throw new Error(data.error?.message || "Invalid Elysium RPC response");
  return data.result as T;
}
export async function assertElysiumRpc(signal?: AbortSignal): Promise<void> {
  const chain = await elysiumRpc<string>("eth_chainId", [], signal);
  if (!/^0x[0-9a-f]+$/i.test(chain) || BigInt(chain) !== BigInt(elysium.id)) throw new Error("RPC returned the wrong Elysium chain ID");
}
