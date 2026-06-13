// Left-navigation layout (wb-aakl.16) — composable from known presets.
//
// Unlike the free-form right dock, the left side is chosen from a small set
// of presets: "rail" (compact, icon-forward — the browser default) and
// "library" (comfortable, full labels — Notion/ClickUp-style). The default
// comes from the onboarding sidebar choice (wb.browser.prefs.sidebar); the
// user can switch later from Settings → Themes → Layout. The canvas +
// titlebar stay static; this only reshapes the sidebar.

import { loadPrefs } from "$lib/onboarding/prefs";

export type NavLayout = "rail" | "library";

const KEY = "wb.nav.layout";

function initialLayout(): NavLayout {
  if (typeof localStorage !== "undefined") {
    const saved = localStorage.getItem(KEY);
    if (saved === "rail" || saved === "library") return saved;
  }
  // Fall back to the onboarding choice, else the rail default.
  const pref = loadPrefs().sidebar;
  return pref === "library" ? "library" : "rail";
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
