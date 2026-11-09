// Turns any uploaded image into a 1-bit-era icon in the Elysium palette (ordered Bayer dither),
// so every meme looks like it belongs on the desktop.
const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
const PALETTE: [number, number, number][] = [
  [0x04, 0x18, 0x1c], // ink
  [0x2d, 0x73, 0x88], // indigo
  [0x34, 0xb7, 0xdd], // cyan
  [0xf8, 0xf7, 0xf4], // paper
];

export async function ditherImage(file: File, size = 128): Promise<string> {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((res, rej) => {
      const i = new Image();
      i.onload = () => res(i);
      i.onerror = rej;
      i.src = url;
    });
    const c = document.createElement("canvas");
    c.width = c.height = size;
    const g = c.getContext("2d")!;
    // Cover-crop to a square.
    const s = Math.min(img.width, img.height);
    g.drawImage(img, (img.width - s) / 2, (img.height - s) / 2, s, s, 0, 0, size, size);
    const px = g.getImageData(0, 0, size, size);
    const d = px.data;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const i = (y * size + x) * 4;
        const l = (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2]) / 255;
        const t = (BAYER[(y % 4) * 4 + (x % 4)] + 0.5) / 16;
        const v = l * 3;
        const idx = Math.min(3, Math.floor(v) + (v - Math.floor(v) > t ? 1 : 0));
        const [r, gg, b] = PALETTE[idx];
        d[i] = r; d[i + 1] = gg; d[i + 2] = b; d[i + 3] = 255;
      }
    }
    g.putImageData(px, 0, 0);
    return c.toDataURL("image/png");
  } finally {
    URL.revokeObjectURL(url);
  }
}
