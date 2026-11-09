import type { Token } from "./market";

/** A meme's coin: its dithered image if it has one, otherwise the ticker stamped on a halftone face. */
export function CoinIcon({ token, size = 40 }: { token: Pick<Token, "ticker" | "image">; size?: number }) {
  return (
    <span className="coin" style={{ width: size, height: size, fontSize: Math.max(8, size * 0.22) }} aria-hidden="true">
      {token.image ? <img src={token.image} alt="" /> : <b>{token.ticker.slice(0, 5)}</b>}
    </span>
  );
}
