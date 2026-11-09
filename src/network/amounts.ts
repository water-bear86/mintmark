import { parseUnits } from "viem";
/** Reject exponent notation, signs, excess decimals and rounding. Never use Number for transaction amounts. */
export function parseHype(value: string): bigint {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(value)) throw new Error("Enter a decimal amount with at most 18 decimals");
  const amount = parseUnits(value, 18);
  if (amount > (1n << 256n) - 1n) throw new Error("Amount exceeds uint256");
  return amount;
}
export function minimumAfterSlippage(amount: bigint, bps: number): bigint {
  if (amount < 0n || !Number.isInteger(bps) || bps < 0 || bps > 10000) throw new Error("Invalid slippage");
  return amount * BigInt(10000 - bps) / 10000n;
}

/** Exact basis points from a user-entered percentage, without floating-point rounding. */
export function parseCreatorFeePercent(value: string): number {
  if (!/^(0|[1-9]\d*)(\.\d{1,2})?$/.test(value)) throw new Error("Enter a creator fee from 0% to 10%, with at most two decimal places.");
  const [whole, fraction = ""] = value.split(".");
  const bps = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
  if (bps > 1000n) throw new Error("Creator fee cannot exceed 10%.");
  return Number(bps);
}
export function formatFeePercent(bps: number): string {
  return `${Math.floor(bps / 100)}.${String(bps % 100).padStart(2, "0")}`;
}
