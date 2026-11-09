import { toggleTheme, useTheme } from "./theme";

export function ThemeToggle() {
  const t = useTheme();
  const label = t === "dark" ? "Switch to light mode" : "Switch to dark mode";
  return (
    <button className="theme-toggle" onClick={toggleTheme} aria-label={label} title={label}>
      <span aria-hidden="true">◐</span>
    </button>
  );
}
