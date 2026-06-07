/**
 * iconAccent — derive a highest-saturation accent color from an icon
 * (emoji, image data-URL, or initials). Used to theme the stroke + faint
 * fill of selected workspace / package tiles so a personal color reads
 * through without overpowering the glyph.
 *
 * Results cache forever; a `version` rune bumps on each compute so
 * reactive readers see the value land on the next render. Returns null
 * for empty icons, low-chroma glyphs, and canvas/decode failures — the
 * caller falls back to default styling on null.
 */

const cache = new Map<string, string | null>();
const inFlight = new Set<string>();
let version = $state(0);

/** Reactive accessor — cached accent or null while computing. Reading
 *  triggers a compute if not started yet. */
export function iconAccent(icon: string): string | null {
  void version; // re-run callers' $derived when a compute lands.
  if (!icon) return null;
  if (cache.has(icon)) return cache.get(icon)!;
  if (!inFlight.has(icon)) {
    inFlight.add(icon);
    void compute(icon).then((c) => {
      cache.set(icon, c);
      inFlight.delete(icon);
      version++;
    });
  }
  return null;
}

async function compute(icon: string): Promise<string | null> {
  try {
    return icon.startsWith("data:image/")
      ? await fromImage(icon)
      : await fromEmoji(icon);
  } catch {
    return null;
  }
}

async function fromImage(dataUrl: string): Promise<string | null> {
  const img = new Image();
  img.src = dataUrl;
  await img.decode();
  return rasterAndPick(img, 32);
}

async function fromEmoji(glyph: string): Promise<string | null> {
  const size = 36;
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const ctx = c.getContext("2d");
  if (!ctx) return null;
  ctx.font = `${size - 4}px "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(glyph, size / 2, size / 2);
  return pickFromImageData(ctx.getImageData(0, 0, size, size));
}

function rasterAndPick(img: HTMLImageElement, size: number): string | null {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const ctx = c.getContext("2d");
  if (!ctx) return null;
  ctx.drawImage(img, 0, 0, size, size);
  return pickFromImageData(ctx.getImageData(0, 0, size, size));
}

/** Walk the pixel buffer once; keep the most-saturated pixel that is
 *  opaque, mid-lightness (drop background + anti-alias fringe), and has
 *  non-trivial chroma (so grayscale glyphs return null). */
function pickFromImageData(img: ImageData): string | null {
  const d = img.data;
  let best: { r: number; g: number; b: number; s: number } | null = null;
  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3] < 200) continue;
    const r = d[i], g = d[i + 1], b = d[i + 2];
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const l = (max + min) / 2;
    if (l < 30 || l > 225) continue;
    const chroma = max - min;
    if (chroma < 30) continue;
    const denom = 255 - Math.abs(2 * l - 255);
    const s = denom === 0 ? 0 : chroma / denom;
    if (!best || s > best.s) best = { r, g, b, s };
  }
  return best ? `rgb(${best.r}, ${best.g}, ${best.b})` : null;
}

/** Faint fill (default 10% alpha) from an `rgb(r, g, b)` accent. */
export function accentFill(accent: string, alpha = 0.1): string {
  const m = /^rgb\((\d+),\s*(\d+),\s*(\d+)\)$/.exec(accent);
  return m ? `rgba(${m[1]}, ${m[2]}, ${m[3]}, ${alpha})` : "transparent";
}

/** Data-URL images are full-bleed inside their tile — skip the accent
 *  border so it doesn't cover the image. */
export function isImageIcon(icon: string): boolean {
  return !!icon && icon.startsWith("data:image/");
}
