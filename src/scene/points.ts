// Square additive pixels. Positions come from the geometry.
export const pointsVert = /* glsl */ `
  uniform float uSize;
  uniform float uAlpha;
  attribute vec3 aSeed;
  varying float vA;
  void main() {
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = uSize * (0.4 + aSeed.y * 0.8) / -mv.z;
    vA = uAlpha;
  }
`;

export const pointsFrag = /* glsl */ `
  uniform vec3 uColor;
  varying float vA;
  void main() {
    // Square pixels, with a soft falloff toward the edges for the bloom halo.
    vec2 q = abs(gl_PointCoord - 0.5) * 2.0;
    float d = max(q.x, q.y);
    float a = 1.0 - smoothstep(0.55, 1.0, d);
    gl_FragColor = vec4(uColor * a * vA, a * vA);
  }
`;
