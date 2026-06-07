/**
 * iconAccent — pick a highest-saturation accent color from an icon
 * (emoji, image data URL, or initials/empty). Used to theme the
 * stroke + faint fill of selected workspace / package tiles so a
 * personal-color reads through without overpowering the glyph.
 *
 * Pure async/canvas implementation; results are cached forever. A
 * `version` rune bumps on each new compute so reactive readers see
 * the value land on the next render.
 *
 * Returns null for:
 *   - empty icon (uses default theme color)
 *   - icons we can't extract a meaningfully-saturated color from
 *     (very low chroma — grayscale glyph, white-on-black initials)
 *   - canvas / decode failures
 *
 * The caller decides what to do with null (typically: skip the accent
 * styling and fall back to default border/bg).
 */

const cache = new Map<string, string | null>();
const inFlight = new Set<string>();

let version = $state(0);

/** Reactive accessor — returns the cached accent or null while
 *  computing. Reading triggers a compute if not started yet. */
export function iconAccent(icon: string): string | null {
  // Touch the version rune so any change re-runs the caller's $derived.
  void version;
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
    if (icon.startsWith("data:image/")) return await fromImage(icon);
    return await fromEmoji(icon);
  } catch {
    return null;
  }
}

async function fromImage(dataUrl: string): Promise<string | null> {
  const img = new Image();
  img.src = dataUrl;
  // decode() resolves once the image is ready; throws on failure.
  await img.decode();
  return rasterAndPick(img, 32);
}

async function fromEmoji(glyph: string): Promise<string | null> {
  const size = 36;
  const c = document.createElement("canvas");
  c.width = size;
  c.height = size;
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
  c.width = size;
  c.height = size;
  const ctx = c.getContext("2d");
  if (!ctx) return null;
  ctx.drawImage(img, 0, 0, size, size);
  return pickFromImageData(ctx.getImageData(0, 0, size, size));
}

/**
 * Walk the pixel buffer once; track the single pixel with the highest
 * HSL saturation among those that are
 *   (a) sufficiently opaque (alpha >= 200) so we ignore halo,
 *   (b) of mid-range lightness (drop near-black and near-white so we
 *       don't pick the background or anti-aliasing fringe),
 *   (c) with non-trivial chroma (max-min channel diff >= 30) so
 *       grayscale glyphs return null and let the caller fall back.
 */
function pickFromImageData(img: ImageData): string | null {
  const data = img.data;
  let best: { r: number; g: number; b: number; s: number } | null = null;
  for (let i = 0; i < data.length; i += 4) {
    const a = data[i + 3];
    if (a < 200) continue;
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const l = (max + min) / 2;
    if (l < 30 || l > 225) continue;
    const d = max - min;
    if (d < 30) continue;
    // HSL saturation, [0,1].
    const denom = 255 - Math.abs(2 * l - 255);
    const s = denom === 0 ? 0 : d / denom;
    if (!best || s > best.s) best = { r, g, b, s };
  }
  if (!best) return null;
  return `rgb(${best.r}, ${best.g}, ${best.b})`;
}

/**
 * Helper: derive the faint fill (10% alpha) from an `rgb(r, g, b)`
 * accent. Callers usually want both the solid stroke and a
 * faint-fill variant; this avoids duplicating the parse.
 */
export function accentFill(accent: string, alpha = 0.10): string {
  const m = /^rgb\((\d+),\s*(\d+),\s*(\d+)\)$/.exec(accent);
  if (!m) return "transparent";
  return `rgba(${m[1]}, ${m[2]}, ${m[3]}, ${alpha})`;
}

/** True when the icon string is a data-URL image — those are full-bleed
 *  inside their tile, so the accent treatment is skipped to avoid
 *  covering the image with a colored border. */
export function isImageIcon(icon: string): boolean {
  return !!icon && icon.startsWith("data:image/");
}
