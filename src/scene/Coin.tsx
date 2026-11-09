import { useEffect, useMemo, useRef } from "react";
import { useFrame } from "@react-three/fiber";
import * as THREE from "three";
import { scroll, smooth, bump, clamp, coinT, curvePoint } from "../timeline";
import { POOL, CTA_COIN } from "./world";
import { CHICAGO, whenChicago } from "./chicago";

const TAU = Math.PI * 2;

// Stamp is designed for the 1-bit dither: white = ink after the inversion, black = paper,
// pure green = lettering that the dither pass draws solid instead of dithering.
function makeStamp() {
  const size = 1024;
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const tex = new THREE.CanvasTexture(c);
  tex.anisotropy = 8;
  const draw = () => {
    const g = c.getContext("2d")!;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.fillStyle = "#000";
    g.fillRect(0, 0, size, size);
    g.translate(size / 2, size / 2);
    g.strokeStyle = g.fillStyle = "#fff";
    g.lineWidth = 34;
    g.beginPath();
    g.arc(0, 0, size * 0.455, 0, TAU);
    g.stroke();
    // Reeded inner ring of square dots.
    for (let i = 0; i < 48; i++) {
      g.save();
      g.rotate((i / 48) * TAU);
      g.fillRect(-9, -size * 0.385 - 9, 18, 18);
      g.restore();
    }
    g.fillStyle = "#00ff00"; // lettering marker, see Dither
    g.textAlign = "center";
    g.textBaseline = "middle";
    g.font = `${size * 0.2}px ${CHICAGO}`;
    g.fillText("$FORGE", 0, -size * 0.02);
    g.font = `${size * 0.075}px ${CHICAGO}`;
    g.fillText("EVM · 0001", 0, size * 0.17);
    tex.needsUpdate = true;
  };
  whenChicago(draw);
  return tex;
}

const faceVert = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const faceFrag = /* glsl */ `
  uniform float uTime;
  uniform float uHeat;
  uniform float uFlip;
  uniform sampler2D uStamp;
  varying vec2 vUv;

  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
  }
  float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; }
    return v;
  }

  void main() {
    vec2 uv = vec2(vUv.y, 1.0 - vUv.x);
    if (uFlip > 0.5) uv.x = 1.0 - uv.x;
    vec3 st = texture2D(uStamp, uv).rgb;
    float s = st.r;                      // rim + reeding
    float txt = clamp(st.g - st.r, 0.0, 1.0); // lettering
    // Cool face: flat light tone (cyan halftone after dither). Molten: flowing mid tones.
    float m = fbm(uv * 5.0 + vec2(uTime * 0.07, -uTime * 0.11));
    float face = mix(0.07, 0.03 + 0.3 * m, uHeat);
    float sweep = smoothstep(0.06, 0.0, abs(fract(uv.x * 0.6 + uv.y * 0.4 - uTime * 0.06) - 0.5)) * 0.06;
    float v = mix(face + sweep, 1.25, s);
    gl_FragColor = vec4(mix(vec3(v), vec3(0.0, 1.0, 0.0), txt), 1.0);
    #include <tonemapping_fragment>
    #include <colorspace_fragment>
  }
`;

export function Coin() {
  const group = useRef<THREE.Group>(null!);
  const stamp = useMemo(makeStamp, []);
  const tmp = useMemo(() => new THREE.Vector3(), []);
  const rotY = useRef(0);

  const faceTop = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: faceVert,
        fragmentShader: faceFrag,
        uniforms: { uTime: { value: 0 }, uHeat: { value: 1 }, uFlip: { value: 0 }, uStamp: { value: stamp } },
      }),
    [stamp],
  );
  const faceBottom = useMemo(() => {
    const m = faceTop.clone();
    m.uniforms.uStamp.value = stamp;
    m.uniforms.uFlip.value = 1;
    return m;
  }, [faceTop, stamp]);
  // Edge reads as an ink outline.
  const side = useMemo(() => new THREE.MeshBasicMaterial({ color: new THREE.Color(1.1, 1.1, 1.1) }), []);
  const materials = useMemo(() => [side, faceTop, faceBottom], [side, faceTop, faceBottom]);

  useEffect(() => () => { stamp.dispose(); faceTop.dispose(); faceBottom.dispose(); side.dispose(); }, [stamp, faceTop, faceBottom, side]);

  useFrame((state, dt) => {
    const b = scroll.beat;
    const t = scroll.reduced ? 0 : state.clock.elapsedTime;
    dt = Math.min(dt, 0.05);

    const ct = coinT(b);
    const heat = clamp(
      1 - smooth(0.2, 1.05, b) +
        0.35 * Math.pow(ct, 4) * (1 - smooth(2.9, 3.1, b)) +
        0.75 * bump(b, 3.2, 3.3, 3.75),
    );
    for (const m of [faceTop, faceBottom]) {
      m.uniforms.uTime.value = t;
      m.uniforms.uHeat.value = heat;
    }

    const p = tmp.set(0, Math.sin(t * 0.9) * 0.06, 0);
    if (b >= 2 && b < 2.75) curvePoint(ct, p).z += 0.3 * smooth(2.0, 2.1, b); // ride just in front of the ribbon
    else if (b >= 2.75 && b < 3.25) {
      const k = (b - 2.75) / 0.5;
      curvePoint(1, p).lerp(POOL, k);
      p.y += Math.sin(Math.PI * k) * 1.6;
      p.z += 0.3 * (1 - k); // continue from the in-front-of-ribbon offset without a pop
    } else if (b >= 3.25 && b < 4.5) {
      p.copy(POOL);
      p.y -= 0.7 * smooth(3.3, 3.95, b);
    } else if (b >= 4.5) {
      p.copy(CTA_COIN);
      p.y += Math.sin(t * 0.9) * 0.05;
    }
    group.current.position.copy(p);

    const scale = b < 3.4 ? 1 : b < 5.3 ? 1 - smooth(3.4, 3.95, b) : smooth(5.3, 5.9, b);
    group.current.scale.setScalar(Math.max(scale, 0.0001));
    group.current.visible = scale > 0.001;

    // Face-on (with a gentle wobble) so the stamp stays readable; it only flips during the jump into the pool.
    const face = 1 - smooth(2.72, 2.8, b) * (1 - smooth(3.3, 3.45, b));
    const speed = 5;
    rotY.current += dt * speed * (1 - face) * (scroll.reduced ? 0 : 1);
    if (face > 0) {
      const target = Math.round(rotY.current / TAU) * TAU + Math.sin(t * 0.55) * 0.32;
      rotY.current += (target - rotY.current) * (1 - Math.exp(-dt * 5 * face));
    }
    group.current.rotation.set(0.06 + Math.sin(t * 0.4) * 0.05, rotY.current, Math.sin(t * 0.3) * 0.04);
  });

  return (
    <group ref={group}>
      <group rotation={[Math.PI / 2, 0, 0]}>
        <mesh material={materials}>
          <cylinderGeometry args={[1, 1, 0.13, 96, 1]} />
        </mesh>
      </group>
    </group>
  );
}
