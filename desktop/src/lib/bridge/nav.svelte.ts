// Left-navigation layout (wb-aakl.16) — chosen from three named presets:
//   shelf — compact, bookmark-forward, few workspaces (the browser default)
//   hub   — a far-left workspace icon-rail + section panel (many workspaces)
//   map   — comfortable, full labels, nested page tree
// The default comes from the onboarding sidebar choice (wb.browser.prefs
// .sidebar); the user can switch later from Settings → Themes → Layout. The
// canvas + titlebar stay static; this only reshapes the sidebar.

import { loadPrefs } from "$lib/onboarding/prefs";

export type NavLayout = "shelf" | "hub" | "map";

const KEY = "wb.nav.layout";

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

class NavStore {
  layout = $state<NavLayout>(initialLayout());

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
}

export const nav = new NavStore();
