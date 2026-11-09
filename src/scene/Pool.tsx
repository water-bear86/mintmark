import { useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import * as THREE from "three";
import { scroll, smooth, clamp, splash } from "../timeline";
import { POOL } from "./world";

const vert = /* glsl */ `
  varying vec2 vUv;
  varying vec3 vW;
  void main() {
    vUv = uv;
    vec4 w = modelMatrix * vec4(position, 1.0);
    vW = w.xyz;
    gl_Position = projectionMatrix * viewMatrix * w;
  }
`;
const frag = /* glsl */ `
  uniform float uTime;
  uniform float uRipple;
  uniform float uSink;
  uniform float uAlpha;
  uniform float uSplash;
  varying vec2 vUv;
  varying vec3 vW;
  void main() {
    vec2 c = vUv - 0.5;
    float r = length(c) * 2.0;
    if (r > 1.0) discard;
    // Ambient swell.
    float swell = sin(r * 26.0 - uTime * 1.2) * 0.5 + 0.5;
    swell = pow(swell, 6.0) * 0.05 * (1.0 - r);
    // Impact rings travel outwards as you scroll.
    float rings = 0.0;
    for (int k = 0; k < 4; k++) {
      float rad = uRipple * 1.3 - float(k) * 0.16;
      rings += exp(-pow((r - rad) * 22.0, 2.0)) * step(0.0, rad) * (1.0 - uRipple) * (1.0 - float(k) * 0.2);
    }
    // Real-time shockwave from the splash: two fast rings racing out from the impact.
    if (uSplash >= 0.0) {
      for (int k = 0; k < 2; k++) {
        float rad = uSplash * 0.75 - float(k) * 0.12;
        rings += exp(-pow((r - rad) * 30.0, 2.0)) * step(0.0, rad) * (1.0 - clamp(uSplash / 1.6, 0.0, 1.0)) * 2.0;
      }
    }
    vec3 base = vec3(0.018, 0.015, 0.013);
    vec3 V = normalize(cameraPosition - vW);
    float fres = pow(1.0 - abs(V.y), 4.0);
    vec3 col = base + vec3(0.83, 0.62, 0.36) * (swell + fres * 0.18);
    col += vec3(1.0, 0.45, 0.12) * rings * 2.6;
    col += vec3(1.0, 0.4, 0.1) * exp(-r * 5.0) * uSink * 1.6;
    float rim = smoothstep(0.93, 0.985, r) * (1.0 - smoothstep(0.985, 1.0, r));
    col += vec3(0.83, 0.66, 0.4) * rim * 1.4;
    float a = uAlpha * smoothstep(1.0, 0.9, r * 0.98);
    gl_FragColor = vec4(col, a);
    #include <tonemapping_fragment>
    #include <colorspace_fragment>
  }
`;

export function Pool() {
  const mat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: vert,
        fragmentShader: frag,
        transparent: true,
        uniforms: { uTime: { value: 0 }, uRipple: { value: 0 }, uSink: { value: 0 }, uAlpha: { value: 0 }, uSplash: { value: -1 } },
      }),
    [],
  );
  useFrame((state) => {
    const b = scroll.beat;
    mat.uniforms.uTime.value = scroll.reduced ? 0 : state.clock.elapsedTime;
    mat.uniforms.uRipple.value = clamp((b - 3.22) / 0.7);
    mat.uniforms.uSplash.value = splash.age;
    mat.uniforms.uSink.value = smooth(3.25, 3.4, b) * (1 - smooth(3.7, 4.1, b));
    mat.uniforms.uAlpha.value = smooth(2.5, 2.9, b) * (1 - smooth(4.0, 4.4, b));
  });
  return (
    <mesh position={POOL} rotation={[-Math.PI / 2, 0, 0]} material={mat}>
      <circleGeometry args={[2.8, 128]} />
    </mesh>
  );
}
