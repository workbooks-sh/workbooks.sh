// Left-navigation layout (wb-aakl.16) — chosen from three named presets:
//   shelf — compact, bookmark-forward, few workspaces (the browser default)
//   hub   — a far-left workspace icon-rail + section panel (many workspaces)
//   map   — comfortable, full labels, nested page tree
// The default comes from the onboarding sidebar choice (wb.browser.prefs
// .sidebar); the user can switch later from Settings → Themes → Layout. The
// canvas + titlebar stay static; this only reshapes the sidebar.

import { loadPrefs } from "$lib/onboarding/prefs";

export type NavLayout = "shelf" | "hub" | "map";

// What sits at the top of the sidebar (wb-aakl.19): a pinned bookmark grid, an
// inline file-system search bar (distinct from the titlebar's global ⌘K
// search), or both.
export type SidebarTop = "bookmarks" | "search" | "both";

// Glyph style (wb-aakl.20): item icons across the sidebar are drawn from the
// icon libraries (Material / LobeHub) or from emoji.
export type GlyphStyle = "icon" | "emoji";

const KEY = "wb.nav.layout";
const TOP_KEY = "wb.nav.sidebarTop";
const GLYPH_KEY = "wb.nav.glyphs";

// Migrate the old two-preset values to the new named set.
function coerce(v: string | null | undefined): NavLayout | null {
  if (v === "shelf" || v === "hub" || v === "map") return v;
  if (v === "rail") return "shelf";
  if (v === "library") return "map";
  return null;
}

function initialLayout(): NavLayout {
  if (typeof localStorage !== "undefined") {
    const saved = coerce(localStorage.getItem(KEY));
    if (saved) return saved;
  }
  // Fall back to the onboarding choice, else the shelf default.
  return coerce(loadPrefs().sidebar) ?? "shelf";
}

function initialSidebarTop(): SidebarTop {
  if (typeof localStorage !== "undefined") {
    const saved = localStorage.getItem(TOP_KEY);
    if (saved === "bookmarks" || saved === "search" || saved === "both") return saved;
    // Migrate the old 2-way bookmarks pref.
    const legacy = localStorage.getItem("wb.nav.bookmarks");
    if (legacy === "search") return "search";
    if (legacy === "pinned") return "bookmarks";
  }
  const pref = loadPrefs().sidebarTop;
  return pref === "search" || pref === "both" ? pref : "bookmarks";
}

function initialGlyphs(): GlyphStyle {
  if (typeof localStorage !== "undefined") {
    const saved = localStorage.getItem(GLYPH_KEY);
    if (saved === "icon" || saved === "emoji") return saved;
  }
  return loadPrefs().glyphs === "emoji" ? "emoji" : "icon";
}

// Per-layout sidebar width (resizable). Each layout remembers its own width —
// Hub is wider by default for the workspace rail. Clamped on read + write.
const W_KEY = "wb.nav.widths";
export const SIDEBAR_MIN = 180;
export const SIDEBAR_MAX = 480;
const DEFAULT_WIDTHS: Record<NavLayout, number> = { shelf: 232, hub: 300, map: 264 };

function initialWidths(): Record<NavLayout, number> {
  const out = { ...DEFAULT_WIDTHS };
  if (typeof localStorage !== "undefined") {
    try {
      const saved = JSON.parse(localStorage.getItem(W_KEY) ?? "{}");
      for (const k of ["shelf", "hub", "map"] as NavLayout[]) {
        const v = Number(saved?.[k]);
        if (Number.isFinite(v) && v >= SIDEBAR_MIN && v <= SIDEBAR_MAX) out[k] = v;
      }
    } catch {
      /* defaults */
    }
  }
  return out;
}

class NavStore {
  layout = $state<NavLayout>(initialLayout());
  widths = $state<Record<NavLayout, number>>(initialWidths());
  sidebarTop = $state<SidebarTop>(initialSidebarTop());
  glyphs = $state<GlyphStyle>(initialGlyphs());

  /** Current layout's sidebar width in px. */
  get sidebarWidth(): number {
    return this.widths[this.layout];
  }

  setLayout(l: NavLayout): void {
    this.layout = l;
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.setItem(KEY, l);
      } catch {
        /* best-effort */
      }
    }
  }

  setSidebarTop(m: SidebarTop): void {
    this.sidebarTop = m;
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.setItem(TOP_KEY, m);
      } catch {
        /* best-effort */
      }
    }
  }

  setGlyphs(g: GlyphStyle): void {
    this.glyphs = g;
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.setItem(GLYPH_KEY, g);
      } catch {
        /* best-effort */
      }
    }
  }

  setSidebarWidth(px: number): void {
    const w = Math.max(SIDEBAR_MIN, Math.min(SIDEBAR_MAX, Math.round(px)));
    this.widths = { ...this.widths, [this.layout]: w };
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.setItem(W_KEY, JSON.stringify(this.widths));
      } catch {
        /* best-effort */
      }
    }
  }
}

export const nav = new NavStore();
