/**
 * Theme store — the dynamic theming system.
 *
 * A theme is a named pair of token maps (light + dark). On activation
 * the matching variant's tokens are written to `:root` as inline custom
 * properties, which beat app.css's `@theme` defaults so switching takes
 * effect immediately without a Tailwind rebuild. Light vs dark follows
 * `matchMedia("(prefers-color-scheme: dark)")` — the OS preference.
 *
 * Data comes from the IPC command layer (`commands.themes*`, mocked).
 * The active-theme id is also mirrored into the persistent store so the
 * choice survives reloads before the backend exists. When the Tauri
 * shell lands, the command layer becomes the source of truth and the
 * store mirror can drop.
 */

import { commands, type Theme, type ThemesSnapshot } from "./bindings";
import { store } from "./store.svelte";
import { ws } from "./ipc";

export type { Theme, ThemesSnapshot };

const ACTIVE_KEY = "themes.activeId";

class ThemesStore {
  themes = $state<Theme[]>([]);
  activeId = $state<string | null>(null);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;
  #mql: MediaQueryList | null = null;
  /** Token names currently applied to :root — tracked so we can drop
   *  stale props when switching to a theme that doesn't define them. */
  #applied = new Set<string>();

  active = $derived<Theme | null>(
    this.themes.find((t) => t.id === this.activeId) ?? null,
  );

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();

    // Prefer the persisted choice over the backend default (mock).
    const persisted = await store.get<string | null>(ACTIVE_KEY);
    if (persisted !== undefined && this.themes.some((t) => t.id === persisted)) {
      this.activeId = persisted;
    }

    ws.onMonorepoChange("themes.org", () => void this.refresh());

    if (typeof window !== "undefined" && window.matchMedia) {
      this.#mql = window.matchMedia("(prefers-color-scheme: dark)");
      this.#mql.addEventListener("change", () => this.applyActive());
    }
    this.applyActive();
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      const snap: ThemesSnapshot = await commands.themesList();
      this.themes = snap.themes;
      this.activeId = snap.active_id;
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async setActive(id: string | null): Promise<void> {
    await commands.themesSetActive(id);
    this.activeId = id;
    await store.set(ACTIVE_KEY, id);
    this.applyActive();
  }

  async create(
    name: string,
    description: string,
    light_tokens: Record<string, string>,
    dark_tokens: Record<string, string>,
  ): Promise<Theme> {
    const t = await commands.themesCreate({ name, description, light_tokens, dark_tokens });
    await this.refresh();
    return t;
  }

  async delete(id: string): Promise<void> {
    await commands.themesDelete(id);
    if (this.activeId === id) await this.setActive(null);
    await this.refresh();
    this.applyActive();
  }

  /** Capture the live `:root` token values as a draft theme — uses the
   *  running app as the editor. */
  snapshotCurrentTokens(): {
    light: Record<string, string>;
    dark: Record<string, string>;
  } {
    const live = this.active;
    if (!live) return { light: {}, dark: {} };
    const cs = getComputedStyle(document.documentElement);
    const out: Record<string, string> = {};
    for (const k of Object.keys({ ...live.light_tokens, ...live.dark_tokens })) {
      const v = cs.getPropertyValue(`--${k}`).trim();
      if (v) out[k] = v;
    }
    return { light: out, dark: out };
  }

  /** Apply the active theme's variant to :root, dropping any stale prop
   *  the new theme doesn't define. */
  applyActive() {
    if (typeof document === "undefined") return;
    const root = document.documentElement;
    const t = this.active;
    if (!t) {
      for (const k of this.#applied) root.style.removeProperty(`--${k}`);
      this.#applied.clear();
      return;
    }
    const prefersDark = this.#mql?.matches ?? false;
    const tokens = prefersDark ? t.dark_tokens : t.light_tokens;
    const nextKeys = new Set(Object.keys(tokens));
    for (const k of this.#applied) {
      if (!nextKeys.has(k)) root.style.removeProperty(`--${k}`);
    }
    for (const [k, v] of Object.entries(tokens)) {
      root.style.setProperty(`--${k}`, v);
    }
    this.#applied = nextKeys;
  }
}

export const themes = new ThemesStore();
