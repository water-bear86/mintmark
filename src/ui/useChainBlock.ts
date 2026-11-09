import { useEffect, useState } from "react";
import { assertElysiumRpc, elysiumRpc } from "../network/elysium";

/** Never display a block from a misconfigured chain, or retain stale data after failure. */
export function useChainBlock() {
  const [block, setBlock] = useState<number | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    const tick = async () => {
      try {
        await assertElysiumRpc(controller.signal);
        const value = await elysiumRpc<string>("eth_blockNumber", [], controller.signal);
        if (!/^0x[0-9a-f]+$/i.test(value)) throw new Error("Invalid block number");
        const number = Number(BigInt(value));
        if (!Number.isSafeInteger(number)) throw new Error("Invalid block number");
        if (!controller.signal.aborted) setBlock(number);
      } catch {
        if (!controller.signal.aborted) setBlock(null);
      } finally {
        if (!controller.signal.aborted) timer = setTimeout(tick, 6000);
      }
    };
    void tick();
    return () => { controller.abort(); clearTimeout(timer); };
  }, []);
  return block;
}
