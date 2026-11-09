import { useSyncExternalStore } from "react";

// Theme: follows the system unless the visitor picks one (saved per browser).
// index.html sets data-theme before first paint so there is no flash.
export type Theme = "light" | "dark";
const KEY = "mintmark.theme";
const mq = window.matchMedia("(prefers-color-scheme: dark)");
const listeners = new Set<() => void>();

function stored(): Theme | null {
  try {
    const v = localStorage.getItem(KEY);
    return v === "light" || v === "dark" ? v : null;
  } catch {
    return null;
  }
}
export const current = (): Theme => (document.documentElement.dataset.theme === "dark" ? "dark" : "light");

function apply(t: Theme) {
  document.documentElement.dataset.theme = t;
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", t === "dark" ? "#04181c" : "#F8F7F4");
  listeners.forEach((l) => l());
}

mq.addEventListener("change", () => { if (!stored()) apply(mq.matches ? "dark" : "light"); });

export function toggleTheme() {
  const next: Theme = current() === "dark" ? "light" : "dark";
  try { localStorage.setItem(KEY, next); } catch { /* private mode: still switch for this visit */ }
  apply(next);
}

export const useTheme = () => useSyncExternalStore((l) => (listeners.add(l), () => listeners.delete(l)), current);
