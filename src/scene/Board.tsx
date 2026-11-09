import { useEffect, useMemo, useRef } from "react";
import { useFrame, type ThreeEvent } from "@react-three/fiber";
import * as THREE from "three";
import { scroll, smooth } from "../timeline";
import { BOARD } from "./world";
import { BOARD_MEMES, setHover, type Launch } from "../launches";
import { CHICAGO, whenChicago } from "./chicago";

// Graduation board: each meme is a stamped coin raised to its bonding-curve progress.
// Everything is drawn white-on-black because the dither inverts it to ink-on-paper.
const SPACING = 1.9;
const H = 4.2; // graduation line height
const R = 0.74;

function coinTexture(l: Launch) {
  const size = 512;
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const tex = new THREE.CanvasTexture(c);
  // Cylinder cap UVs are a quarter turn off; rotate so text reads upright facing the camera.
  tex.center.set(0.5, 0.5);
  tex.rotation = Math.PI / 2;
  tex.anisotropy = 4;
  const draw = () => {
    const g = c.getContext("2d")!;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.fillStyle = "#1c1c1c";
    g.fillRect(0, 0, size, size);
    g.translate(size / 2, size / 2);
    g.strokeStyle = g.fillStyle = "#fff";
    g.lineWidth = 28;
    g.beginPath();
    g.arc(0, 0, size * 0.44, 0, Math.PI * 2);
    g.stroke();
    g.fillStyle = "#00ff00"; // lettering marker: drawn crisp by the dither pass
    g.textAlign = "center";
    g.textBaseline = "middle";
    const label = l.ticker.slice(0, 5);
    g.font = `${size * (label.length > 4 ? 0.17 : 0.2)}px ${CHICAGO}`;
    g.fillText(label, 0, -size * 0.04);
    g.font = `${size * 0.14}px ${CHICAGO}`;
    g.fillText(l.graduated ? "GRAD" : `${Math.round(l.progress * 100)}%`, 0, size * 0.2);
    tex.needsUpdate = true;
  };
  whenChicago(draw);
  return tex;
}

type Slot = { l: Launch; x: number; z: number; y: number; phase: number };

export function Board() {
  const root = useRef<THREE.Group>(null!);
  const coins = useRef<(THREE.Group | null)[]>([]);
  const stems = useRef<(THREE.Mesh | null)[]>([]);

  const slots = useMemo<Slot[]>(() => {
    // One row, ascending left to right, so the board itself reads like the curve.
    const n = BOARD_MEMES.length;
    return BOARD_MEMES.map((l, i) => ({
      l,
      x: (i - (n - 1) / 2) * SPACING,
      z: 0,
      y: l.graduated ? H + 1.1 : Math.max(l.progress, 0.2) * H,
      phase: i * 0.7,
    }));
  }, []);

  const faces = useMemo(() => slots.map((s) => new THREE.MeshBasicMaterial({ map: coinTexture(s.l) })), [slots]);
  const edge = useMemo(() => new THREE.MeshBasicMaterial({ color: new THREE.Color(1.1, 1.1, 1.1) }), []);
  const stemMat = useMemo(() => new THREE.MeshBasicMaterial({ color: new THREE.Color(0.9, 0.9, 0.9) }), []);
  const lineMat = useMemo(() => new THREE.MeshBasicMaterial({ color: new THREE.Color(1, 1, 1) }), []);
  const gradMat = useMemo(
    () => new THREE.MeshBasicMaterial({ color: new THREE.Color(0.1, 0.1, 0.1), transparent: true, depthWrite: false, side: THREE.DoubleSide }),
    [],
  );
  useEffect(() => () => { faces.forEach((m) => { m.map?.dispose(); m.dispose(); }); }, [faces]);

  const width = BOARD_MEMES.length * SPACING + 0.6;
  const dashes = useMemo(() => {
    const out: number[] = [];
    for (let x = -width / 2; x < width / 2; x += 0.5) out.push(x + 0.15);
    return out;
  }, [width]);

  useFrame((state) => {
    const b = scroll.beat;
    const t = scroll.reduced ? 0 : state.clock.elapsedTime;
    const vis = smooth(3.75, 4.2, b) * (1 - smooth(4.9, 5.2, b));
    root.current.visible = vis > 0.001;
    const grow = smooth(3.85, 4.35, b);
    gradMat.opacity = vis;
    slots.forEach((s, i) => {
      const g = coins.current[i];
      const stem = stems.current[i];
      if (!g || !stem) return;
      const y = s.y * grow;
      g.position.set(s.x, y + Math.sin(t * 1.2 + s.phase) * 0.04, s.z);
      g.rotation.y = Math.sin(t * 0.6 + s.phase) * 0.22;
      g.scale.setScalar(Math.max(vis, 0.0001));
      stem.scale.y = Math.max(y, 0.001);
      stem.position.set(s.x, y / 2, s.z);
    });
  });

  const interactive = () => scroll.beat > 3.95 && scroll.beat < 5.15;
  const onMove = (i: number) => (e: ThreeEvent<PointerEvent>) => {
    if (!interactive()) return;
    e.stopPropagation();
    document.body.style.cursor = "pointer";
    setHover({ id: slots[i].l.id, x: e.nativeEvent.clientX, y: e.nativeEvent.clientY });
  };
  const onOut = () => {
    document.body.style.cursor = "";
    setHover(null);
  };

  return (
    <group ref={root} position={BOARD}>
      {/* Base lines per row */}
      <mesh material={lineMat}>
        <boxGeometry args={[width, 0.06, 0.06]} />
      </mesh>
      {/* Graduation line: dashed rail plus a faint plane that dithers into a cyan band */}
      {dashes.map((x) => (
        <mesh key={x} position={[x, H, -0.4]} material={lineMat}>
          <boxGeometry args={[0.28, 0.06, 0.06]} />
        </mesh>
      ))}
      <mesh position={[0, H, -0.4]} rotation={[-Math.PI / 2, 0, 0]} material={gradMat}>
        <planeGeometry args={[width, 1.6]} />
      </mesh>
      {slots.map((s, i) => (
        <group key={s.l.id}>
          <mesh ref={(m) => { stems.current[i] = m; }} material={stemMat}>
            <boxGeometry args={[0.05, 1, 0.05]} />
          </mesh>
          <group ref={(g) => { coins.current[i] = g; }}>
            <mesh
              rotation={[Math.PI / 2, 0, 0]}
              material={[edge, faces[i], faces[i]]}
              onPointerMove={onMove(i)}
              onPointerOut={onOut}
            >
              <cylinderGeometry args={[R, R, 0.1, 48, 1]} />
            </mesh>
          </group>
        </group>
      ))}
    </group>
  );
}
