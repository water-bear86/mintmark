import { forwardRef, useMemo } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import { Effect } from "postprocessing";
import * as THREE from "three";

// 1-bit-era ordered dither. Pixels tagged pure green (coin lettering) skip the dither and render as solid ink.
// The scene is rendered bright-on-black, then inverted onto paper:
// empty space becomes paper, light becomes ink, with Elysium cyan and indigo as the halftone steps.
// Inside the "negative band" (the screen area under the transparent indigo zk section) the ramp flips:
// indigo background, violet and cyan halftones, paper for the brightest shapes.
const frag = /* glsl */ `
  uniform vec3 uPaper;
  uniform vec3 uCyan;
  uniform vec3 uIndigo;
  uniform vec3 uInk;
  uniform vec3 uViolet;
  uniform float uPixel;
  uniform vec2 uNeg; // negative band in uv.y: (bottom, top); empty when bottom >= top
  uniform float uDark; // 1 in dark mode: the whole page is the negative, the band goes light

  float bayer4(vec2 p) {
    p = mod(p, 4.0);
    float x = p.x, y = p.y;
    float m = 0.0;
    if (y < 1.0) m = x < 1.0 ? 0.0 : x < 2.0 ? 8.0 : x < 3.0 ? 2.0 : 10.0;
    else if (y < 2.0) m = x < 1.0 ? 12.0 : x < 2.0 ? 4.0 : x < 3.0 ? 14.0 : 6.0;
    else if (y < 3.0) m = x < 1.0 ? 3.0 : x < 2.0 ? 11.0 : x < 3.0 ? 1.0 : 9.0;
    else m = x < 1.0 ? 15.0 : x < 2.0 ? 7.0 : x < 3.0 ? 13.0 : 5.0;
    return (m + 0.5) / 16.0;
  }

  void mainImage(const in vec4 inputColor, const in vec2 uv, out vec4 outputColor) {
    vec2 cell = floor(uv * resolution / uPixel);
    vec2 suv = (cell + 0.5) * uPixel / resolution;
    vec3 c = texture2D(inputBuffer, suv).rgb;
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float v = 1.0 - exp(-l * 3.6);
    float d = bayer4(cell);
    float x = clamp(v, 0.0, 1.0) * 3.0;
    float base = floor(x);
    float idx = base + step(d, x - base);

    float band = step(uNeg.x, uv.y) * step(uv.y, uNeg.y);
    vec3 light = idx < 0.5 ? uPaper : idx < 1.5 ? uCyan : idx < 2.5 ? uIndigo : uInk;
    vec3 night = idx < 0.5 ? uInk : idx < 1.5 ? uIndigo : idx < 2.5 ? uCyan : uPaper;
    vec3 inv = idx < 0.5 ? uIndigo : idx < 1.5 ? uViolet : idx < 2.5 ? uCyan : uPaper;
    // Light theme: page = light ramp, zk band = indigo negative. Dark theme: page = night ramp, band = light ramp.
    vec3 col = uDark > 0.5 ? mix(night, light, band) : mix(light, inv, band);
    float neg = uDark > 0.5 ? 1.0 - band : band; // which ink the lettering uses

    // Text marker: pure green is never produced by the scene, so it is drawn solid and crisp at full res.
    vec3 raw = texture2D(inputBuffer, uv).rgb;
    float text = step(0.12, raw.g) * step(raw.r * 1.6, raw.g) * step(raw.b * 1.6, raw.g);
    col = mix(col, mix(uInk, uPaper, neg), text);
    outputColor = vec4(col, 1.0);
  }
`;

class DitherEffect extends Effect {
  constructor({ pixel = 2 }: { pixel?: number }) {
    super("DitherEffect", frag, {
      uniforms: new Map<string, THREE.Uniform>([
        ["uPaper", new THREE.Uniform(new THREE.Color("#F8F7F4"))],
        ["uCyan", new THREE.Uniform(new THREE.Color("#34B7DD"))],
        ["uIndigo", new THREE.Uniform(new THREE.Color("#2d7388"))],
        ["uInk", new THREE.Uniform(new THREE.Color("#04181c"))],
        ["uViolet", new THREE.Uniform(new THREE.Color("#1E4D5A"))],
        ["uPixel", new THREE.Uniform(pixel)],
        ["uNeg", new THREE.Uniform(new THREE.Vector2(1, 0))],
        ["uDark", new THREE.Uniform(0)],
      ]),
    });
  }
}

/** Selector of the page element whose on-screen area renders in negative. */
const NEGATIVE = "#zk";

export const Dither = forwardRef<DitherEffect, { pixel?: number }>(function Dither({ pixel = 2 }, ref) {
  const effect = useMemo(() => new DitherEffect({ pixel }), [pixel]);
  const canvas = useThree((s) => s.gl.domElement);
  const band = useMemo(() => ({ el: null as HTMLElement | null }), []);

  // Read the section's live position every frame so the negative edge stays glued to the block.
  useFrame(() => {
    band.el ??= document.querySelector<HTMLElement>(NEGATIVE);
    effect.uniforms.get("uDark")!.value = document.documentElement.dataset.theme === "dark" ? 1 : 0;
    const u = effect.uniforms.get("uNeg")!.value as THREE.Vector2;
    if (!band.el) return void u.set(1, 0);
    const r = band.el.getBoundingClientRect();
    const c = canvas.getBoundingClientRect();
    u.set(1 - (r.bottom - c.top) / c.height, 1 - (r.top - c.top) / c.height);
  });

  return <primitive ref={ref} object={effect} dispose={null} />;
});
