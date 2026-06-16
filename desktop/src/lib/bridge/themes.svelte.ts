/**
 * Themes bridge — mirrors Rust `themes.rs`.
 *
 * A theme is a named pair of token maps (light + dark). On activation,
 * the matching variant's tokens are written to `:root` as inline
 * styles via `setProperty()`. Inline styles beat any rule from
 * `app.css`'s `@theme` block, so switching takes effect immediately
 * without re-building the Tailwind output.
 *
 * Light vs dark variant selection follows `matchMedia
 * "(prefers-color-scheme: dark)"` — the user's OS choice. A future
 * "Force light/dark" toggle can override this.
 */

import { invoke } from "@tauri-apps/api/core";

export interface Theme {
  id: string;
  name: string;
  description: string;
  light_tokens: Record<string, string>;
  dark_tokens: Record<string, string>;
  builtin: boolean;
  created_at: number;
}

export interface ThemesSnapshot {
  active_id: string | null;
  themes: Theme[];
}

class ThemesStore {
  themes = $state<Theme[]>([]);
  activeId = $state<string | null>(null);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;
  #mql: MediaQueryList | null = null;
  /** Tokens currently applied to :root — tracked so we can revert
   *  cleanly when switching themes (don't leave stale custom props
   *  from a previous theme that the new one doesn't define). */
  #applied = new Set<string>();

  active = $derived<Theme | null>(
    this.themes.find((t) => t.id === this.activeId) ?? null,
  );

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();

    // React to OS light/dark changes so a theme with both variants
    // re-applies the right one automatically.
    if (typeof window !== "undefined" && window.matchMedia) {
      this.#mql = window.matchMedia("(prefers-color-scheme: dark)");
      this.#mql.addEventListener("change", () => this.applyActive());
    }
    // Re-apply when the user forces a mode (data-mode flips via the
    // onboarding/settings theme pick) so the inline tokens track the same
    // light/dark decision as app.css instead of drifting to the OS.
    if (typeof document !== "undefined") {
      new MutationObserver(() => this.applyActive()).observe(
        document.documentElement,
        { attributes: true, attributeFilter: ["data-mode"] },
      );
    }
    this.applyActive();
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      const snap = await invoke<ThemesSnapshot>("theme_list");
      this.themes = snap.themes;
      this.activeId = snap.active_id;
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async setActive(id: string | null): Promise<void> {
    // Ignore an UNKNOWN id (a stale/legacy value like "dark", or a bad arg from
    // `work app theme`) — fall back to the default rather than nuking every token
    // into a broken state where fg/page collapse together.
    const next = id === null || this.themes.some((t) => t.id === id) ? id : null;
    await invoke("theme_set_active", { id: next });
    this.activeId = next;
    this.applyActive();
  }

  async create(
    name: string,
    description: string,
    light_tokens: Record<string, string>,
    dark_tokens: Record<string, string>,
  ): Promise<Theme> {
    const t = await invoke<Theme>("theme_create", {
      req: { name, description, light_tokens, dark_tokens },
    });
    await this.refresh();
    return t;
  }

  async update(
    id: string,
    name: string,
    description: string,
    light_tokens: Record<string, string>,
    dark_tokens: Record<string, string>,
  ): Promise<void> {
    await invoke("theme_update", {
      req: { id, name, description, light_tokens, dark_tokens },
    });
    await this.refresh();
    this.applyActive();
  }

  async delete(id: string): Promise<void> {
    await invoke("theme_delete", { id });
    await this.refresh();
    this.applyActive();
  }

  /** Capture the currently-rendered token values as a draft theme.
   *  Reads `getComputedStyle(:root)` for every token in the active
   *  theme; the caller passes the result into `create()` after
   *  letting the user tweak. */
  snapshotCurrentTokens(): {
    light: Record<string, string>;
    dark: Record<string, string>;
  } {
    const live = this.active;
    if (!live) return { light: {}, dark: {} };
    const cs = getComputedStyle(document.documentElement);
    const out: Record<string, string> = {};
    const tokens = Object.keys({
      ...live.light_tokens,
      ...live.dark_tokens,
    });
    for (const t of tokens) {
      const v = cs.getPropertyValue(`--${t}`).trim();
      if (v) out[t] = v;
    }
    return { light: out, dark: out };
  }

  /** Non-reactive read of the token names currently applied to
   *  :root. Used by surfaces (WorkbookView) that want to enumerate
   *  the live tokens without pulling the theme objects into their
   *  reactive dependency graph. Falls back to a built-in list while
   *  nothing has been applied yet. */
  appliedTokenNames(): string[] {
    if (this.#applied.size > 0) return [...this.#applied];
    return [
      "color-page",
      "color-surface",
      "color-surface-soft",
      "color-border",
      "color-border-strong",
      "color-fg",
      "color-fg-muted",
      "color-fg-subtle",
      "color-accent",
      "color-primary-bg",
      "color-primary-fg",
      "color-ring",
      "color-grid-line",
      // Reusable theme gradient (wb-xxbm.6). Themes opt into a custom
      // aurora palette by setting these; otherwise app.css defaults
      // apply.
      "gradient-aurora-a",
      "gradient-aurora-b",
      "gradient-aurora-c",
      "gradient-aurora-d",
    ];
  }

  /** Effective dark/light decision. The user's forced mode (data-mode on
   *  :root, set by the onboarding/settings theme pick) is the source of
   *  truth; only "system" (no data-mode) falls back to the OS preference.
   *  Without this, the inline theme tokens (which beat app.css) followed the
   *  OS while app.css's cascade followed data-mode — so picking Light on a
   *  dark OS left the two systems disagreeing and the UI looked broken. */
  #isDark(): boolean {
    if (typeof document !== "undefined") {
      const mode = document.documentElement.getAttribute("data-mode");
      if (mode === "dark") return true;
      if (mode === "light") return false;
    }
    return this.#mql?.matches ?? false;
  }

  /** Apply the active theme's tokens to :root. Drops any previously-
   *  applied custom property that the new theme doesn't define. */
  applyActive() {
    const root = document.documentElement;
    const t = this.active;
    if (!t) {
      for (const k of this.#applied) root.style.removeProperty(`--${k}`);
      this.#applied.clear();
      return;
    }
    const tokens = this.#isDark() ? t.dark_tokens : t.light_tokens;
    const nextKeys = new Set(Object.keys(tokens));

    // Remove stale props from the previous theme.
    for (const k of this.#applied) {
      if (!nextKeys.has(k)) root.style.removeProperty(`--${k}`);
    }
    // Apply the new ones.
    for (const [k, v] of Object.entries(tokens)) {
      root.style.setProperty(`--${k}`, v);
    }
    this.#applied = nextKeys;
  }
}

export const themes = new ThemesStore();
