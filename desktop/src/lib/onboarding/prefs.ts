// Personalization prefs (wb-aakl.20) — the choices the onboarding flow
// captures, persisted to localStorage and applied at boot. The theme mode
// is applied here (data-mode on :root, honored by app.css); the sidebar
// layout is consumed by the composable nav (wb-aakl.16) and search by the
// search registry (wb-aakl.19) — all reading this same blob.

export type ThemeMode = "system" | "dark" | "light";

export interface BrowserPrefs {
  theme: ThemeMode;
  sidebar: "shelf" | "hub" | "map";
  bookmarks: "pinned" | "search";
  search: { ai: "summary" | "first" | "off" };
}

const KEY = "wb.browser.prefs";

export function loadPrefs(): Partial<BrowserPrefs> {
  if (typeof localStorage === "undefined") return {};
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "{}") ?? {};
  } catch {
    return {};
  }
}

/** Force a color mode (or follow the OS for "system"). app.css applies the
 *  dark tokens under :root[data-mode="dark"] and the OS media query only
 *  when no data-mode is set. */
export function applyThemeMode(mode: ThemeMode): void {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  if (mode === "system") root.removeAttribute("data-mode");
  else root.setAttribute("data-mode", mode);
}

/** Apply persisted prefs at boot. Currently the theme mode; sidebar/search
 *  are read by their own consumers. */
export function applyBootPrefs(): void {
  const p = loadPrefs();
  if (p.theme) applyThemeMode(p.theme);
}
