import { useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import * as THREE from "three";
import { scroll, smooth } from "../timeline";
import { pointsVert, pointsFrag } from "./points";

const SPARKS = 220;

const sparkVert = /* glsl */ `
  uniform float uTime;
  uniform float uAlpha;
  uniform float uSize;
  attribute vec3 aSeed;
  varying float vA;
  varying float vLife;
  void main() {
    float life = fract(aSeed.x + uTime * (0.08 + aSeed.y * 0.16));
    vec3 p = vec3(
      (aSeed.z - 0.5) * 3.2 * (1.0 - life * 0.5) + sin(uTime * 1.7 + aSeed.x * 31.0) * 0.25 * life,
      -2.8 + life * 6.0,
      (aSeed.y - 0.5) * 2.2 - 0.4
    );
    vec4 mv = modelViewMatrix * vec4(p, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = uSize * (1.0 - life * 0.7) * (0.5 + aSeed.z) / -mv.z;
    vLife = life;
    vA = uAlpha * (1.0 - life) * smoothstep(0.0, 0.08, life);
  }
`;
const sparkFrag = /* glsl */ `
  varying float vA;
  varying float vLife;
  void main() {
    vec2 q = abs(gl_PointCoord - 0.5) * 2.0;
    float a = (1.0 - smoothstep(0.55, 1.0, max(q.x, q.y))) * vA;
    vec3 col = mix(vec3(3.0, 1.5, 0.5), vec3(2.2, 0.35, 0.06), vLife);
    gl_FragColor = vec4(col * a, a);
  }
`;

const glowFrag = /* glsl */ `
  uniform float uHeat;
  varying vec2 vUv;
  void main() {
    float d = length(vUv - 0.5) * 2.0;
    float a = pow(max(1.0 - d, 0.0), 2.4) * uHeat;
    gl_FragColor = vec4(vec3(1.0, 0.3, 0.07) * a * 0.9, a);
  }
`;
const uvVert = /* glsl */ `
  varying vec2 vUv;
  void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }
`;

export function Forge() {
  const sparks = useMemo(() => {
    const g = new THREE.BufferGeometry();
    const seed = new Float32Array(SPARKS * 3).map(() => Math.random());
    g.setAttribute("position", new THREE.BufferAttribute(new Float32Array(SPARKS * 3), 3));
    g.setAttribute("aSeed", new THREE.BufferAttribute(seed, 3));
    return g;
  }, []);
  const sparkMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: sparkVert,
        fragmentShader: sparkFrag,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        uniforms: { uTime: { value: 0 }, uAlpha: { value: 1 }, uSize: { value: 70 } },
      }),
    [],
  );
  const glowMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: uvVert,
        fragmentShader: glowFrag,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        uniforms: { uHeat: { value: 1 } },
      }),
    [],
  );

  // Ambient dust across the whole world for depth.
  const dust = useMemo(() => {
    const n = 1400;
    const g = new THREE.BufferGeometry();
    const pos = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      pos[i * 3] = -8 + Math.random() * 30;
      pos[i * 3 + 1] = -5 + Math.random() * 14;
      pos[i * 3 + 2] = -30 + Math.random() * 38;
    }
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("aSeed", new THREE.BufferAttribute(new Float32Array(n * 3).map(() => Math.random()), 3));
    return g;
  }, []);
  const dustMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: pointsVert,
        fragmentShader: pointsFrag,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        uniforms: { uAlpha: { value: 0.5 }, uSize: { value: 40 }, uColor: { value: new THREE.Color("#D4A866") } },
      }),
    [],
  );

  useFrame((state) => {
    const b = scroll.beat;
    const t = scroll.reduced ? 1.5 : state.clock.elapsedTime;
    const heat = 1 - smooth(0.2, 1.1, b);
    sparkMat.uniforms.uTime.value = t;
    sparkMat.uniforms.uAlpha.value = heat;
    glowMat.uniforms.uHeat.value = (0.25 + heat * 0.75) * (1 - smooth(1.3, 1.9, b));
  });

  return (
    <group>
      <mesh position={[0, -0.3, -2]} material={glowMat}>
        <planeGeometry args={[9, 9]} />
      </mesh>
      <points geometry={sparks} material={sparkMat} frustumCulled={false} />
      <points geometry={dust} material={dustMat} frustumCulled={false} />
    </group>
  );
}
