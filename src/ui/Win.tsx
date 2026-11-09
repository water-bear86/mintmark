import { useRef, useState, type CSSProperties, type ReactNode } from "react";

let topZ = 10;

/** Early-desktop window. Drag it by the title bar with a mouse. */
export function Win({ title, children, className = "", style, meta, drag: draggable = true }: {
  title: string; children: ReactNode; className?: string; style?: CSSProperties; meta?: string;
  /** App windows stay put; lander windows can be dragged around. */
  drag?: boolean;
}) {
  const [off, setOff] = useState({ x: 0, y: 0 });
  const [z, setZ] = useState(0);
  const drag = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null);
  const onDown = (e: React.PointerEvent) => {
    if (!draggable || e.pointerType !== "mouse") return;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    drag.current = { x: e.clientX, y: e.clientY, ox: off.x, oy: off.y };
  };
  const onMove = (e: React.PointerEvent) => {
    const d = drag.current;
    if (d) setOff({ x: d.ox + e.clientX - d.x, y: d.oy + e.clientY - d.y });
  };
  const onUp = () => { drag.current = null; };
  return (
    <div
      className={`win ${className}`}
      style={{ ...style, translate: `${off.x}px ${off.y}px`, zIndex: z || undefined }}
      onPointerDown={() => setZ(++topZ)}
    >
      <div className={`titlebar ${draggable ? "" : "fixed"}`} onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp}>
        <span className="box" aria-hidden="true" />
        <span className="title">{title}</span>
        {meta && <span className="meta">{meta}</span>}
        <span className="box zoom" aria-hidden="true" />
      </div>
      <div className="win-body">{children}</div>
    </div>
  );
}

