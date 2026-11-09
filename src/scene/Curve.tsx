import { useMemo, useRef } from "react";
import { useFrame } from "@react-three/fiber";
import * as THREE from "three";
import { scroll, smooth, bump, coinT, curvePoint, CURVE_LEN, CURVE_DEPTH } from "../timeline";
import { pointsVert, pointsFrag } from "./points";

class BondingCurve extends THREE.Curve<THREE.Vector3> {
  constructor() {
    super();
  }
  getPoint(t: number, out = new THREE.Vector3()) {
    return curvePoint(t, out);
  }
}

const ribbonVert = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;
const ribbonFrag = /* glsl */ `
  uniform float uTime;
  uniform float uFill;
  uniform float uReveal;
  uniform float uAlpha;
  uniform float uGlow;
  varying vec2 vUv;
  void main() {
    float a = vUv.x;
    if (a > uReveal) discard;
    float filled = step(a, uFill);
    float pulse = pow(0.5 + 0.5 * sin(a * 42.0 - uTime * 4.0), 10.0) * filled;
    vec3 hot = mix(vec3(1.0, 0.33, 0.08), vec3(1.0, 0.72, 0.35), a) * (2.2 + pulse * 3.0);
    vec3 cold = vec3(0.83, 0.66, 0.4) * 0.45;
    vec3 col = mix(cold, hot, filled);
    float edge = 1.0 - smoothstep(0.0, 0.02, uReveal - a);
    col += vec3(1.0, 0.8, 0.5) * edge * 4.0;
    float alpha = uAlpha * mix(1.0, 0.35, uGlow);
    gl_FragColor = vec4(col * alpha, alpha);
  }
`;

const BUYERS = 320;

export function Curve() {
  const curve = useMemo(() => new BondingCurve(), []);
  const core = useMemo(() => new THREE.TubeGeometry(curve, 400, 0.028, 10), [curve]);
  const halo = useMemo(() => new THREE.TubeGeometry(curve, 400, 0.12, 12), [curve]);
  const mkMat = (glow: number) =>
    new THREE.ShaderMaterial({
      vertexShader: ribbonVert,
      fragmentShader: ribbonFrag,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      uniforms: {
        uTime: { value: 0 }, uFill: { value: 0 }, uReveal: { value: 0 },
        uAlpha: { value: 0 }, uGlow: { value: glow },
      },
    });
  const coreMat = useMemo(() => mkMat(0), []);
  const haloMat = useMemo(() => mkMat(1), []);

  // Chart axes: baseline + faint gridlines.
  const axes = useMemo(() => {
    const pts: number[] = [];
    const end = new THREE.Vector3(CURVE_LEN, 0, CURVE_DEPTH);
    pts.push(0, 0, 0, end.x, end.y, end.z);
    for (let i = 1; i <= 4; i++) {
      const t = i / 4;
      const p = curvePoint(t, new THREE.Vector3());
      pts.push(t * CURVE_LEN, 0, t * CURVE_DEPTH, p.x, p.y, p.z);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(pts, 3));
    return g;
  }, []);
  const axesMat = useMemo(
    () => new THREE.LineBasicMaterial({ color: "#D4A866", transparent: true, opacity: 0 }),
    [],
  );

  // Buyers: sparks streaming up the curve into the coin.
  const buyers = useMemo(() => {
    const g = new THREE.BufferGeometry();
    const pos = new Float32Array(BUYERS * 3);
    const seed = new Float32Array(BUYERS * 3);
    for (let i = 0; i < BUYERS; i++) {
      seed[i * 3] = Math.random();
      seed[i * 3 + 1] = Math.random();
      seed[i * 3 + 2] = Math.random();
    }
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("aSeed", new THREE.BufferAttribute(seed, 3));
    return g;
  }, []);
  const buyersMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: pointsVert,
        fragmentShader: pointsFrag,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        uniforms: { uAlpha: { value: 0 }, uSize: { value: 110 }, uColor: { value: new THREE.Color(2.4, 1.2, 0.45) } },
      }),
    [],
  );

  // Graduation ring at the top of the curve.
  const ring = useRef<THREE.Mesh>(null!);
  const ringMat = useMemo(
    () => new THREE.MeshBasicMaterial({ color: new THREE.Color(1.6, 1.1, 0.55), transparent: true, opacity: 0, toneMapped: false }),
    [],
  );
  const ringPos = useMemo(() => curvePoint(1, new THREE.Vector3()), []);
  const ringQuat = useMemo(() => {
    const tan = curve.getTangent(1).normalize();
    return new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 0, 1), tan);
  }, [curve]);

  const tmp = useMemo(() => new THREE.Vector3(), []);

  useFrame((state) => {
    const b = scroll.beat;
    const t = scroll.reduced ? 0 : state.clock.elapsedTime;
    const ct = coinT(b);
    const vis = smooth(1.45, 1.95, b) * (1 - smooth(3.9, 4.3, b));
    const reveal = smooth(1.55, 2.0, b);
    for (const m of [coreMat, haloMat]) {
      m.uniforms.uTime.value = t;
      m.uniforms.uFill.value = ct;
      m.uniforms.uReveal.value = reveal * 1.001;
      m.uniforms.uAlpha.value = vis;
    }
    axesMat.opacity = 0.14 * vis;

    const active = smooth(1.9, 2.05, b) * (1 - smooth(2.75, 2.9, b));
    buyersMat.uniforms.uAlpha.value = active;
    const pos = buyers.attributes.position as THREE.BufferAttribute;
    const seed = buyers.attributes.aSeed as THREE.BufferAttribute;
    if (active > 0.001) {
      for (let i = 0; i < BUYERS; i++) {
        const s0 = seed.getX(i), s1 = seed.getY(i), s2 = seed.getZ(i);
        const life = (s0 + t * (0.18 + s1 * 0.2)) % 1;
        const along = Math.max(ct, 0.02) * life;
        curvePoint(along, tmp);
        const spread = (1 - life) * 0.9;
        tmp.x += (s1 - 0.5) * spread * 0.6;
        tmp.y += (s2 - 0.5) * spread + Math.sin(t * 3 + s0 * 40) * 0.03;
        tmp.z += (s0 - 0.5) * spread;
        pos.setXYZ(i, tmp.x, tmp.y, tmp.z);
      }
      pos.needsUpdate = true;
    }

    const flash = bump(b, 2.72, 2.8, 3.0);
    ringMat.opacity = vis * (0.35 + 0.65 * smooth(2.4, 2.75, b)) ;
    ringMat.color.setRGB(1.6 + flash * 4, 1.1 + flash * 2.5, 0.55 + flash);
    ring.current.scale.setScalar(1 + flash * 0.5 + Math.sin(t * 2) * 0.03);
  });

  return (
    <group>
      <mesh geometry={halo} material={haloMat} frustumCulled={false} />
      <mesh geometry={core} material={coreMat} frustumCulled={false} />
      <lineSegments geometry={axes} material={axesMat} />
      <points geometry={buyers} material={buyersMat} frustumCulled={false} />
      <mesh ref={ring} position={ringPos} quaternion={ringQuat} material={ringMat}>
        <torusGeometry args={[0.5, 0.025, 12, 96]} />
      </mesh>
    </group>
  );
}
