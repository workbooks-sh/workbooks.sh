/**
 * tint — the ONE per-item accent source (wb-5fl.14). The same name gets
 * the same color on every surface: folder glyph, app row icon, bookmark
 * tile, workbook cube.
 *
 * Default is a deterministic hash onto a brand-adjacent palette; users
 * can override per name from the context-menu hue arc (TintArc). Hue
 * arcs emit hsl() at fixed saturation/lightness so every pickable color
 * reads on both light and dark. Overrides persist locally today; the
 * backend `:color:` orgprop (wb-5fl.12) is the eventual home.
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

const STORE_KEY = "tint.overrides";

function loadOverrides(): Record<string, string> {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY) ?? "{}");
  } catch {
    return {};
  }
}

class TintStore {
  overrides = $state<Record<string, string>>(loadOverrides());

  #persist() {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(this.overrides));
    } catch {
      /* non-fatal */
    }
  }

  set(name: string, color: string) {
    this.overrides = { ...this.overrides, [name]: color };
    this.#persist();
  }

  clear(name: string) {
    const { [name]: _, ...rest } = this.overrides;
    this.overrides = rest;
    this.#persist();
  }
}

export const tints = new TintStore();

function hashColor(name: string): string {
  // FNV-1a — the naive *31 hash clustered common short names onto the
  // same palette slot (Kanban + Notes both teal).
  let h = 2166136261;
  for (let i = 0; i < name.length; i++) {
    h ^= name.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return PALETTE[Math.abs(h) % PALETTE.length];
}

export function tintFor(name: string): string {
  return tints.overrides[name] ?? hashColor(name);
}

/** A soft wash of the tint for chip/tile backgrounds. */
export function tintWash(tint: string, pct = 10): string {
  return `color-mix(in srgb, ${tint} ${pct}%, var(--color-surface))`;
}
