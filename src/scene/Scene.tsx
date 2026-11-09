import { Canvas } from "@react-three/fiber";
import { EffectComposer, Bloom, ToneMapping } from "@react-three/postprocessing";
import { ToneMappingMode } from "postprocessing";
import * as THREE from "three";
import { Coin } from "./Coin";
import { Curve } from "./Curve";
import { Forge } from "./Forge";
import { Pool } from "./Pool";
import { Board } from "./Board";
import { Splash } from "./Splash";
import { Rig } from "./Rig";
import { Dither } from "./Dither";
import { scroll } from "../timeline";

export default function Scene({ lite, onReady }: { lite: boolean; onReady: () => void }) {
  return (
    <Canvas
      className="stage"
      dpr={lite ? [1, 1.5] : [1, 2]}
      camera={{ fov: 38, near: 0.1, far: 120, position: [0, 0.2, 5.6] }}
      gl={{ antialias: !lite, powerPreference: "high-performance", toneMapping: THREE.ACESFilmicToneMapping }}
      onCreated={(state) => {
        state.gl.setClearColor("#000000");
        if (import.meta.env.DEV) Object.assign(window, { __r3f: state, __scroll: scroll });
        requestAnimationFrame(() => requestAnimationFrame(onReady));
      }}
    >
      <fog attach="fog" args={["#000000", 20, 50]} />

      <Rig />
      <Forge />
      <Coin />
      <Curve />
      <Pool />
      <Splash />
      <Board />

      <EffectComposer multisampling={0}>
        {!lite ? <Bloom mipmapBlur intensity={0.8} luminanceThreshold={1.4} luminanceSmoothing={0.3} radius={0.7} /> : <></>}
        <ToneMapping mode={ToneMappingMode.ACES_FILMIC} />
        <Dither pixel={Math.round(2 * Math.min(window.devicePixelRatio || 1, lite ? 1.5 : 2))} />
      </EffectComposer>
    </Canvas>
  );
}
