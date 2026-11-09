import type { Address, Hex } from "viem";

/** JSON-safe intent recorded before a wallet receives a transaction request. */
export type SubmissionIntent = {
  version: 1;
  chainId: 99801 | 99901;
  from: Address;
  to: Address;
  nonce: number;
  data: Hex;
  value: string;
};
export type StoredSubmission = { intent: SubmissionIntent } | { legacy: true };
const isAddress = (value: unknown): value is Address => typeof value === "string" && /^0x[0-9a-f]{40}$/i.test(value);
export function parseStoredSubmission(raw: string | null): StoredSubmission | null {
  if (raw === null) return null;
  try {
    const value = JSON.parse(raw) as Partial<SubmissionIntent>;
    if (value.version === 1 && (value.chainId === 99801 || value.chainId === 99901)
      && isAddress(value.from) && isAddress(value.to) && Number.isSafeInteger(value.nonce) && value.nonce! >= 0
      && typeof value.data === "string" && /^0x(?:[0-9a-f]{2})*$/i.test(value.data)
      && typeof value.value === "string" && /^(0|[1-9][0-9]*)$/.test(value.value)) return { intent: value as SubmissionIntent };
  } catch { /* Old account-only records and malformed records must fail closed. */ }
  return { legacy: true };
}
export function matchesSubmission(intent: SubmissionIntent, chainId: number, tx: { from: string; to: string | null; nonce: number; input: string; value: bigint }): boolean {
  return chainId === intent.chainId && tx.from.toLowerCase() === intent.from.toLowerCase()
    && tx.to?.toLowerCase() === intent.to.toLowerCase() && tx.nonce === intent.nonce
    && tx.input.toLowerCase() === intent.data.toLowerCase() && tx.value === BigInt(intent.value);
}

export type RecoveryStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;
/** Migrate same-tab legacy records without discarding a conflicting durable record. */
export function readRecovery(durable: RecoveryStorage, legacy: RecoveryStorage, key: string): { hash: Hex | null; uncertain: StoredSubmission | null } {
  let conflict = false;
  for (const name of [key, `${key}.uncertain`]) {
    const old = legacy.getItem(name), current = durable.getItem(name);
    if (old !== null) {
      if (current !== null && current !== old) { conflict = true; continue; }
      if (current === null) durable.setItem(name, old);
      legacy.removeItem(name);
    }
  }
  if (conflict) return { hash: null, uncertain: { legacy: true } };
  const rawHash = durable.getItem(key);
  const hash = rawHash && /^0x[0-9a-f]{64}$/i.test(rawHash) ? rawHash as Hex : null;
  return { hash, uncertain: rawHash !== null && !hash ? { legacy: true } : parseStoredSubmission(durable.getItem(`${key}.uncertain`)) };
}
/** Best-effort cross-tab guard, not an atomic distributed lock. Never overwrite an existing recovery record. */
export function persistSubmissionIntent(durable: RecoveryStorage, legacy: RecoveryStorage, key: string, intent: SubmissionIntent): void {
  readRecovery(durable, legacy, key);
  if ([key, `${key}.uncertain`].some(name => durable.getItem(name) !== null || legacy.getItem(name) !== null)) throw new Error("A previous transaction needs reconciliation. Reload to recover it before submitting again.");
  durable.setItem(`${key}.uncertain`, JSON.stringify(intent));
}
export function clearRecoveryKey(durable: RecoveryStorage, legacy: RecoveryStorage, key: string): void {
  durable.removeItem(key); legacy.removeItem(key);
}
export function persistPendingHash(durable: RecoveryStorage, legacy: RecoveryStorage, key: string, hash: Hex): void {
  const prior = durable.getItem(key), old = legacy.getItem(key);
  if ((prior !== null && prior !== hash) || (old !== null && old !== hash)) throw new Error("Another pending transaction needs reconciliation");
  durable.setItem(key, hash);
  clearRecoveryKey(durable, legacy, `${key}.uncertain`);
}
