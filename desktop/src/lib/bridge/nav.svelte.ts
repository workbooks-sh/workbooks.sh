// Left-navigation layout (wb-aakl.16) — chosen from three named presets:
//   shelf — compact, bookmark-forward, few workspaces (the browser default)
//   hub   — a far-left workspace icon-rail + section panel (many workspaces)
//   map   — comfortable, full labels, nested page tree
// The default comes from the onboarding sidebar choice (wb.browser.prefs
// .sidebar); the user can switch later from Settings → Themes → Layout. The
// canvas + titlebar stay static; this only reshapes the sidebar.

import { loadPrefs } from "$lib/onboarding/prefs";

export type NavLayout = "shelf" | "hub" | "map";

// Bookmarks surface (wb-aakl.16/.19): "pinned" = a pinned bookmark grid in the
// sidebar alongside search; "search" = no pinned grid, you recall things
// through search instead.
export type BookmarksMode = "pinned" | "search";

const KEY = "wb.nav.layout";
const BM_KEY = "wb.nav.bookmarks";

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

function initialBookmarks(): BookmarksMode {
  if (typeof localStorage !== "undefined") {
    const saved = localStorage.getItem(BM_KEY);
    if (saved === "pinned" || saved === "search") return saved;
  }
  return loadPrefs().bookmarks === "search" ? "search" : "pinned";
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
  bookmarks = $state<BookmarksMode>(initialBookmarks());

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

  setBookmarks(m: BookmarksMode): void {
    this.bookmarks = m;
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.setItem(BM_KEY, m);
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
