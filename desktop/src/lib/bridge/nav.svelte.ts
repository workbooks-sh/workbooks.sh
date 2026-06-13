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

// Titlebar layout (wb-aakl.16). Tabs are always present; the layout only
// changes the OTHER chrome around them:
//   slim  — tabs + nexus status + Waldo; secondary actions live in the ⌄ menu
//   bench — Search / Bookmarks / Terminal surfaced as visible bar buttons
//   helm  — a slim command/search field sits in the bar for quick navigate
export type TitlebarLayout = "slim" | "bench" | "helm";

const KEY = "wb.nav.layout";
const TB_KEY = "wb.nav.titlebar";

function initialLayout(): NavLayout {
  if (typeof localStorage !== "undefined") {
    const saved = localStorage.getItem(KEY);
    if (saved === "rail" || saved === "library") return saved;
  }
  // Fall back to the onboarding choice, else the rail default.
  const pref = loadPrefs().sidebar;
  return pref === "library" ? "library" : "rail";
}

function initialTitlebar(): TitlebarLayout {
  if (typeof localStorage !== "undefined") {
    const saved = localStorage.getItem(TB_KEY);
    if (saved === "slim" || saved === "bench" || saved === "helm") return saved;
  }
  const pref = loadPrefs().titlebar;
  return pref === "bench" || pref === "helm" ? pref : "slim";
}

class NavStore {
  layout = $state<NavLayout>(initialLayout());
  titlebar = $state<TitlebarLayout>(initialTitlebar());

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

  setTitlebar(t: TitlebarLayout): void {
    this.titlebar = t;
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.setItem(TB_KEY, t);
      } catch {
        /* best-effort */
      }
    }
  }
}

export const nav = new NavStore();
