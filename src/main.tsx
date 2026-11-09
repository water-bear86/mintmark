import { lazy, StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

// The lander (with its 3D scene) and the app are separate bundles; each path loads only what it needs.
const Lander = lazy(() => import("./App"));
const AppRoot = lazy(() => import("./app/AppRoot"));
const isApp = location.pathname.startsWith("/app");

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Suspense fallback={null}>{isApp ? <AppRoot /> : <Lander />}</Suspense>
  </StrictMode>,
);
