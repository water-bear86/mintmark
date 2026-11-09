import { useSyncExternalStore } from "react";

// Sample data for the lander. Replaced by the indexer feed once the app ships.
export type Launch = {
  id: number;
  name: string;
  ticker: string;
  mcapUsd: number;
  change24h: number;
  progress: number;
  graduated: boolean;
  ageMin: number;
};

const NAMES = [
  "Ember", "Anvil", "Bellows", "Quench", "Tongs", "Slag", "Ingot", "Crucible", "Rivet", "Temper",
  "Flux", "Billet", "Smelt", "Chisel", "Hammer Time", "Gas Goblin", "Orbit Frog", "Testnet Sam",
  "Blue Line", "Cinder", "Forge Cat", "Spark", "Molten Mike", "Rollup Rat", "Proof Pup", "Kiln",
  "Ore", "Brass Monkey", "Hearth", "Alloy", "Patina", "Lodestone", "Mint Condition", "Char",
  "Blaze", "Coldcast", "Scoria", "Gild", "Pewter", "Bronze Age", "Iron Maiden Fan", "Tinder",
  "Wrought", "Mint Frog", "Hype Lizard", "Consensus Cow", "Block Party", "Shard",
  "Nugget", "Solder", "Carbon", "Meteorite", "Obsidian", "Magma", "Pyre", "Furnace", "Ashes",
  "Vulcan", "Tempest", "Rebar", "Steelman", "Copperhead", "Zinc", "Cobalt",
];

function rng(seed: number) {
  return () => {
    seed = (seed * 1664525 + 1013904223) % 4294967296;
    return seed / 4294967296;
  };
}

const r = rng(7);
export const LAUNCHES: Launch[] = NAMES.map((name, id) => {
  const graduated = r() < 0.18;
  const progress = graduated ? 1 : Math.pow(r(), 1.6);
  const mcapUsd = graduated ? 55_000 + r() * 900_000 : 4_000 + progress * 50_000 * (0.8 + r() * 0.4);
  const ticker = name.replace(/[^A-Za-z]/g, "").slice(0, 5).toUpperCase();
  return {
    id,
    name,
    ticker,
    mcapUsd,
    change24h: (r() - 0.42) * (graduated ? 80 : 240),
    progress,
    graduated,
    ageMin: Math.floor(r() * 2800) + 2,
  };
});

/** The graduation board: two graduated memes plus six spread across the curve, so it reads as a ramp. */
const climbing = LAUNCHES.filter((l) => !l.graduated);
const pick = (target: number, taken: Set<number>) =>
  climbing
    .filter((l) => !taken.has(l.id))
    .reduce((best, l) => (Math.abs(l.progress - target) < Math.abs(best.progress - target) ? l : best));
const taken = new Set<number>();
export const BOARD_MEMES: Launch[] = [
  ...[0.18, 0.34, 0.5, 0.64, 0.78, 0.92].map((t) => {
    const l = pick(t, taken);
    taken.add(l.id);
    return l;
  }),
  ...LAUNCHES.filter((l) => l.graduated).slice(0, 2),
];

export const fmtUsd = (n: number) =>
  "$" + new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(n);
export const fmtPct = (n: number) => `${n >= 0 ? "+" : ""}${n.toFixed(1)}%`;

// Tiny store for the hovered star so the Canvas never re-renders on hover.
type Hover = { id: number; x: number; y: number } | null;
let hover: Hover = null;
const listeners = new Set<() => void>();
export const setHover = (h: Hover) => {
  if (h?.id === hover?.id && h?.x === hover?.x && h?.y === hover?.y) return;
  hover = h;
  listeners.forEach((l) => l());
};
export const useHover = () =>
  useSyncExternalStore(
    (l) => (listeners.add(l), () => listeners.delete(l)),
    () => hover,
  );
