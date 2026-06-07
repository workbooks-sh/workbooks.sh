// Brand-aware color picking with contrast guarantees. Used by both the
// document and presentation renderers to pick a heading color that's
// readable on the page background, without ditching brand identity.
//
// The naive `palette[0]` approach falls apart on brands whose dominant
// scraped color is white or near-white (like Vercel: #ffffff is the most-
// used color). Headings then come out invisible on the white stage.
//
// pickThemeColors() returns {primary, secondary, accent} where:
//   - primary = the FIRST palette color with luminance < 0.5 (i.e. dark
//     enough to read on a light background). Falls back to "#181818".
//   - secondary = the inverse — first LIGHT color, defaulting to white.
//   - accent = the first chromatic color (saturation > 0.3) that isn't
//     primary/secondary, falling back to a sensible blue.

export interface ThemeColors {
  primary: string;   // dark, used for headings + text on light bg
  secondary: string; // light, used for surfaces
  accent: string;    // chromatic, used for highlights / links / borders
  source: "scraped" | "scraped+fallback" | "fallback";
}

export interface PaletteEntry { hex: string; name?: string; role?: string }

const DEFAULT_PRIMARY = "#181818";
const DEFAULT_SECONDARY = "#ffffff";
const DEFAULT_ACCENT = "#1f6feb";

export function pickThemeColors(palette: PaletteEntry[]): ThemeColors {
  const valid = palette
    .filter((p) => /^#[0-9a-f]{6}$/i.test(p.hex))
    .map((p) => ({ ...p, hex: p.hex.toLowerCase() }));

  const primary = valid.find((p) => luminance(p.hex) < 0.5)?.hex ?? DEFAULT_PRIMARY;
  const secondary = valid.find((p) => luminance(p.hex) >= 0.85)?.hex ?? DEFAULT_SECONDARY;
  const accent = valid.find((p) =>
    p.hex !== primary && p.hex !== secondary && saturation(p.hex) >= 0.25
  )?.hex ?? DEFAULT_ACCENT;

  const fromScrape = valid.length > 0;
  const allDefaults = primary === DEFAULT_PRIMARY && secondary === DEFAULT_SECONDARY && accent === DEFAULT_ACCENT;
  return {
    primary, secondary, accent,
    source: !fromScrape ? "fallback" : (allDefaults ? "scraped+fallback" : "scraped"),
  };
}

/** WCAG-style relative luminance in [0, 1]. */
export function luminance(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  }) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** Saturation in [0, 1]. 0 = grayscale. */
export function saturation(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((v) => v / 255) as [number, number, number];
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  if (max === 0) return 0;
  return (max - min) / max;
}

/** Pick foreground color (#fff or #111) that meets WCAG AA against bg. */
export function readableForeground(bgHex: string): string {
  return luminance(bgHex) > 0.5 ? "#111111" : "#ffffff";
}

function hexToRgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16),
  ];
}
