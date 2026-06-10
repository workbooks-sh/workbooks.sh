/**
 * tint — deterministic accent color for a named thing (bookmark tile
 * washes, avatars). Hashes the name onto a brand-adjacent palette so
 * the same name always gets the same hue. Item ICONS come from the
 * universal icon library (material/emoji — fixed colors); tint only
 * colors chrome around them now. The per-item color picker (TintArc)
 * was retired with the material migration.
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
  // FNV-1a — the naive *31 hash clustered common short names onto the
  // same palette slot (Kanban + Notes both teal).
  let h = 2166136261;
  for (let i = 0; i < name.length; i++) {
    h ^= name.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return PALETTE[Math.abs(h) % PALETTE.length];
}

/** A soft wash of the tint for chip/tile backgrounds. */
export function tintWash(tint: string, pct = 10): string {
  return `color-mix(in srgb, ${tint} ${pct}%, var(--color-surface))`;
}
