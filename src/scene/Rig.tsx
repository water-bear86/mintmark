import { useMemo, useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";
import { scroll, smooth } from "../timeline";
import { CTA_COIN } from "./world";

type KF = {
  b: number; pos: [number, number, number]; tgt: [number, number, number];
  portraitLift?: number;
  /** On portrait screens, recentre camera and target on this x (desktop shots offset the subject for copy). */
  portraitX?: number;
};

// Camera shot list. Each keyframe is a beat; the rig eases between them.
const SHOTS: KF[] = [
  { b: 0.0, pos: [0, 0.2, 7], tgt: [-1.9, 0, 0], portraitLift: 2.3 },   // hero: coin right of copy
  { b: 0.85, pos: [0.3, 0.1, 6.1], tgt: [1.75, 0, 0], portraitLift: 1.4 }, // cast: coin left, close
  { b: 1.3, pos: [0.2, 0.05, 5.8], tgt: [1.7, 0, 0], portraitLift: 1.4 },
  { b: 2.0, pos: [3.4, 1.6, 13.5], tgt: [2.9, 2.0, -0.8], portraitLift: 0.6 }, // curve wide
  { b: 2.7, pos: [5.6, 2.9, 11.5], tgt: [4.6, 2.7, -0.8], portraitLift: 0.4 },
  { b: 3.05, pos: [7.4, 3.2, 10.5], tgt: [6.4, 1.8, -1.2], portraitLift: 0.2 },  // ring + pool
  { b: 3.6, pos: [9.6, 3.4, 7.4], tgt: [7.9, 0.0, -1.4], portraitLift: 0 },
  { b: 4.15, pos: [11, 3.3, 0.6], tgt: [11, 2.55, -16], portraitLift: -2.4 },  // graduation board
  { b: 4.9, pos: [11.9, 3.8, -0.4], tgt: [11.3, 2.55, -16], portraitLift: -2.4 },
  { b: 5.4, pos: [11, 3.2, -0.5], tgt: [11, 2.6, -18], portraitLift: 0 },     // fly in
  { b: 6.0, pos: [CTA_COIN.x - 1.45, 3.1, -2.3], tgt: [CTA_COIN.x - 1.45, CTA_COIN.y - 1.2, CTA_COIN.z], portraitLift: -0.6, portraitX: CTA_COIN.x }, // cta: coin right of the headline
];

// Dev aid: ?snap skips camera easing so screenshots land exactly on a shot.
const SNAP = import.meta.env.DEV && location.search.includes("snap");

export function Rig() {
  const { camera, size, pointer } = useThree();
  const pos = useMemo(() => new THREE.Vector3(...SHOTS[0].pos), []);
  const tgt = useMemo(() => new THREE.Vector3(...SHOTS[0].tgt), []);
  const wantPos = useMemo(() => new THREE.Vector3(), []);
  const wantTgt = useMemo(() => new THREE.Vector3(), []);
  const a = useMemo(() => new THREE.Vector3(), []);
  const c = useMemo(() => new THREE.Vector3(), []);
  const first = useRef(true);

  useFrame((state, dt) => {
    const b = scroll.beat;
    const portrait = size.width / size.height < 0.85;
    let i = 0;
    while (i < SHOTS.length - 2 && b > SHOTS[i + 1].b) i++;
    const k0 = SHOTS[i], k1 = SHOTS[i + 1];
    const k = smooth(k0.b, k1.b, b);
    const shot = (kf: KF, p: THREE.Vector3, t: THREE.Vector3) => {
      p.set(...kf.pos);
      t.set(...kf.tgt);
      if (portrait) {
        // Center the subject, lift it below the copy, and back off to fit the narrow frame.
        const lift = kf.portraitLift ?? 0;
        if (kf.b < 1.5) t.x = 0, p.x = 0;
        if (kf.portraitX !== undefined) t.x = p.x = kf.portraitX;
        t.y += lift;
        p.y += lift;
        p.sub(t).multiplyScalar(1.55).add(t);
      }
    };
    shot(k0, wantPos, wantTgt);
    shot(k1, a, c);
    wantPos.lerp(a, k);
    wantTgt.lerp(c, k);

    // CTA: slow orbit around the coin.
    const orbit = smooth(5.6, 6.0, b);
    if (orbit > 0 && !scroll.reduced) {
      const ang = Math.sin(state.clock.elapsedTime * 0.25) * 0.35 * orbit;
      a.copy(wantPos).sub(CTA_COIN).applyAxisAngle(new THREE.Vector3(0, 1, 0), ang);
      wantPos.copy(CTA_COIN).add(a);
    }

    // Cursor parallax.
    if (!scroll.reduced && !portrait) {
      wantPos.x += pointer.x * 0.28;
      wantPos.y += pointer.y * 0.16;
    }

    const damp = first.current || scroll.reduced || SNAP ? 1 : 1 - Math.exp(-Math.min(dt, 0.05) * 5);
    first.current = false;
    pos.lerp(wantPos, damp);
    tgt.lerp(wantTgt, damp);
    camera.position.copy(pos);
    camera.lookAt(tgt);
  });
  return null;
}
