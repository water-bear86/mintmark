import { useMemo, useRef } from "react";
import { useFrame } from "@react-three/fiber";
import * as THREE from "three";
import { scroll, splash, SPLASH_BEAT } from "../timeline";
import { POOL } from "./world";

// Fires once when the coin crosses into the pool, then plays in real time so it never goes slow-mo
// under a slow scroll. Scrolling back above the landing re-arms it.
const DROPS = 260;
const DURATION = 1.8;

const vert = /* glsl */ `
  uniform float uAge;
  uniform float uSize;
  attribute vec4 aDrop; // x: angle, y: horizontal speed, z: vertical speed, w: kind (0 crown, 1 jet)
  varying float vA;
  void main() {
    float jet = aDrop.w;
    float t = uAge - jet * 0.22;            // the jet rises just after the crown
    float g = 9.0;
    vec3 dir = vec3(cos(aDrop.x), 0.0, sin(aDrop.x));
    vec3 p = position + dir * aDrop.y * t + vec3(0.0, aDrop.z * t - 0.5 * g * t * t, 0.0);
    float alive = step(0.0, t) * step(position.y - 0.02, p.y);
    vec4 mv = modelViewMatrix * vec4(p, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = uSize * mix(1.0, 0.45, clamp(t / 1.2, 0.0, 1.0)) * (0.6 + fract(aDrop.x * 7.13) * 0.8) / -mv.z;
    vA = alive;
  }
`;
const frag = /* glsl */ `
  varying float vA;
  void main() {
    if (vA < 0.5) discard;
    gl_FragColor = vec4(vec3(2.2), 1.0);
  }
`;

// Crown sheet: an open cylinder that flares out and collapses.
const crownFrag = /* glsl */ `
  uniform float uAlpha;
  varying vec2 vUv;
  void main() {
    float lip = smoothstep(0.55, 1.0, vUv.y);
    float v = mix(0.1, 1.4, lip) * uAlpha;
    gl_FragColor = vec4(vec3(v), 1.0);
  }
`;
const crownVert = /* glsl */ `
  varying vec2 vUv;
  void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }
`;

export function Splash() {
  const prev = useRef(0);
  const t0 = useRef(-1);
  const crown = useRef<THREE.Mesh>(null!);

  const geo = useMemo(() => {
    const g = new THREE.BufferGeometry();
    const pos = new Float32Array(DROPS * 3);
    const drop = new Float32Array(DROPS * 4);
    for (let i = 0; i < DROPS; i++) {
      const jet = i < DROPS * 0.22 ? 1 : 0;
      const a = Math.random() * Math.PI * 2;
      const r = jet ? Math.random() * 0.12 : 0.5 + Math.random() * 0.3;
      pos[i * 3] = POOL.x + Math.cos(a) * r;
      pos[i * 3 + 1] = POOL.y;
      pos[i * 3 + 2] = POOL.z + Math.sin(a) * r;
      drop[i * 4] = a;
      drop[i * 4 + 1] = jet ? Math.random() * 0.35 : 1.1 + Math.random() * 1.6;
      drop[i * 4 + 2] = jet ? 4.2 + Math.random() * 2.2 : 2.2 + Math.random() * 2.6;
      drop[i * 4 + 3] = jet;
    }
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("aDrop", new THREE.BufferAttribute(drop, 4));
    return g;
  }, []);
  const mat = useMemo(
    () => new THREE.ShaderMaterial({ vertexShader: vert, fragmentShader: frag, uniforms: { uAge: { value: -1 }, uSize: { value: 105 } } }),
    [],
  );
  const crownMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: crownVert,
        fragmentShader: crownFrag,
        side: THREE.DoubleSide,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        uniforms: { uAlpha: { value: 0 } },
      }),
    [],
  );

  useFrame((state) => {
    const b = scroll.beat;
    const now = state.clock.elapsedTime;
    if (!scroll.reduced && prev.current < SPLASH_BEAT && b >= SPLASH_BEAT && b < SPLASH_BEAT + 0.4) t0.current = now;
    if (b < SPLASH_BEAT - 0.1) t0.current = -1;
    prev.current = b;

    let age = t0.current < 0 ? -1 : now - t0.current;
    // Dev aid: window.__splashAge = 0.3 freezes the splash at that moment for screenshots.
    if (import.meta.env.DEV) {
      const forced = (window as unknown as { __splashAge?: number }).__splashAge;
      if (typeof forced === "number") age = forced;
    }
    const live = age >= 0 && age < DURATION;
    splash.age = live ? age : -1;
    mat.uniforms.uAge.value = live ? age : -1;

    const c = crown.current;
    c.visible = live && age < 0.7;
    if (c.visible) {
      const k = age / 0.7;
      const rise = Math.sin(Math.PI * Math.min(k * 1.3, 1));
      c.scale.set(0.45 + k * 1.3, Math.max(rise * 0.9, 0.001), 0.45 + k * 1.3);
      c.position.set(POOL.x, POOL.y + (rise * 0.9) / 2, POOL.z);
      crownMat.uniforms.uAlpha.value = 1 - k;
    }
  });

  return (
    <group>
      <points geometry={geo} material={mat} frustumCulled={false} />
      <mesh ref={crown} material={crownMat} visible={false}>
        <cylinderGeometry args={[1, 0.7, 1, 48, 1, true]} />
      </mesh>
    </group>
  );
}
