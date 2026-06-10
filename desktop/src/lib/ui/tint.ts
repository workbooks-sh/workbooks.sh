/**
 * tint — deterministic accent color for a named thing (app tiles, avatars).
 * Hashes the name onto a fixed brand-adjacent palette so the same app
 * always gets the same hue, and a sidebar full of apps reads as a
 * considered set rather than random rainbow. Brand blue leads the list.
 */
const PALETTE = [
  "#2f6fe0", // brand blue
  "#0d9488", // teal
  "#7c3aed", // violet
  "#d97706", // amber
  "#0284c7", // sky
  "#dc2626", // red
  "#c026d3", // fuchsia
  "#4f46e5", // indigo
];

export function tintFor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) | 0;
  return PALETTE[Math.abs(h) % PALETTE.length];
}

/** A soft wash of the tint for chip/tile backgrounds. */
export function tintWash(tint: string, pct = 10): string {
  return `color-mix(in srgb, ${tint} ${pct}%, var(--color-surface))`;
}
