// workponents · theme registry — the browser/artifact-side theme runtime.
//
// The desktop Rust layer (store.rs `Theme{id,name,light_tokens,dark_tokens}`)
// + themes.svelte.ts are the AUTHORING/PERSISTENCE side and speak `--color-*`.
// This is the COMPLEMENT they were missing: a zero-dependency runtime that any
// workbook artifact (a static .html with no Tauri, no desktop) carries with it,
// so a workbook can register + apply a `--work-*` theme on hydrate.
//
// A theme is data, not CSS:
//
//   {
//     id: "signal",
//     name: "Signal",
//     extends: "dark",                      // base preset to inherit ("light"|"dark")
//     tokens: { light: { "work-bg": "#…", … }, dark: { … } },
//     fonts:  { sans: "…", mono: "…" },     // optional; map to --work-font / --work-font-mono
//   }
//
// Token KEYS are bare names ("work-bg"), NOT `--work-bg` — applyTheme writes the
// `--` prefix, exactly like themes.svelte.ts writes `--${k}`. This keeps the
// registry data shape identical to the Rust registry's token maps.
//
// apply/revert mirrors themes.svelte.ts `applyActive()`: write each token inline
// on the scope element (inline styles beat tokens.css's `:root` rule and any
// `data-work-theme` rule), track the applied set, and remove stale props from a
// previous theme before applying the new one so themes never bleed into each
// other. One scope element is themed at a time; pass a different scope to theme a
// subtree (a per-artifact brand region).

/** id → theme record */
const _registry = new Map();
/** scope element → { id, mode, applied:Set<string> } */
const _active = new WeakMap();
/** the last scope applyTheme touched, so activeTheme()/revert default to it */
let _lastScope = null;

/** The font tokens a theme's `fonts` map drives, by font key. */
const FONT_TOKENS = { sans: "work-font", mono: "work-font-mono", display: "work-font-display" };

/**
 * Register (or replace) a theme. Returns the stored record.
 * @param {object} theme { id, name, extends?, tokens:{light,dark}, fonts? }
 */
export function registerTheme(theme) {
  if (!theme || typeof theme.id !== "string" || !theme.id) {
    throw new Error("registerTheme: theme.id (string) is required");
  }
  const rec = {
    id: theme.id,
    name: theme.name || theme.id,
    extends: theme.extends === "dark" ? "dark" : "light",
    tokens: {
      light: { ...(theme.tokens && theme.tokens.light) },
      dark: { ...(theme.tokens && theme.tokens.dark) },
    },
    fonts: { ...(theme.fonts || {}) },
  };
  _registry.set(rec.id, rec);
  return rec;
}

/** All registered theme records (in registration order). */
export function listThemes() {
  return [..._registry.values()];
}

/** A single registered theme record, or null. */
export function getTheme(id) {
  return _registry.get(id) || null;
}

/**
 * Resolve the flat token map a theme applies for a given mode.
 * Merges fonts into the token map (fonts.sans → work-font, etc.).
 * @returns {Record<string,string>} bare-name token map ("work-bg": "#…")
 */
export function resolveTokens(id, mode = "light") {
  const t = _registry.get(id);
  if (!t) return {};
  const base = mode === "dark" ? t.tokens.dark : t.tokens.light;
  const out = { ...base };
  for (const [fk, tok] of Object.entries(FONT_TOKENS)) {
    if (t.fonts && t.fonts[fk]) out[tok] = t.fonts[fk];
  }
  return out;
}

function pickScope(scope) {
  if (scope) return scope;
  if (typeof document !== "undefined") return document.documentElement;
  return null;
}

/**
 * Apply a registered theme to a scope element by writing `--work-*` inline.
 * Mirrors themes.svelte.ts applyActive(): removes stale props from whatever
 * theme was last applied to this scope, then writes the new set. Also reflects
 * the chosen mode onto `data-work-theme` so the tokens.css preset rule and the
 * inline override agree.
 *
 * @param {string} id registered theme id
 * @param {object} [opts]
 * @param {"light"|"dark"} [opts.mode="light"]
 * @param {Element} [opts.scope] element to theme (default: documentElement)
 * @returns {{id:string, mode:string, tokens:Record<string,string>}}
 */
export function applyTheme(id, { mode = "light", scope } = {}) {
  const el = pickScope(scope);
  if (!el) throw new Error("applyTheme: no scope element (no document)");
  const t = _registry.get(id);
  if (!t) throw new Error(`applyTheme: unknown theme "${id}"`);

  const tokens = resolveTokens(id, mode);
  const nextKeys = new Set(Object.keys(tokens));

  const prev = _active.get(el);
  if (prev) {
    for (const k of prev.applied) {
      if (!nextKeys.has(k)) el.style.removeProperty(`--${k}`);
    }
  }
  for (const [k, v] of Object.entries(tokens)) {
    el.style.setProperty(`--${k}`, v);
  }
  // Keep the preset selector in sync — extend the base preset, label the scope.
  el.setAttribute("data-work-theme", mode === "dark" ? "dark" : "light");

  _active.set(el, { id, mode, applied: nextKeys });
  _lastScope = el;
  return { id, mode, tokens };
}

/**
 * Revert a scope to its un-themed state — drops every inline `--work-*` this
 * registry applied, so tokens.css's defaults take over again.
 */
export function revertTheme(scope) {
  const el = pickScope(scope);
  if (!el) return;
  const prev = _active.get(el);
  if (prev) {
    for (const k of prev.applied) el.style.removeProperty(`--${k}`);
    _active.delete(el);
  }
  el.removeAttribute("data-work-theme");
  if (_lastScope === el) _lastScope = null;
}

/**
 * The theme currently applied to a scope (default: the last scope applyTheme
 * touched, else documentElement). Returns { id, mode } or null.
 */
export function activeTheme(scope) {
  const el = pickScope(scope || _lastScope);
  if (!el) return null;
  const a = _active.get(el);
  return a ? { id: a.id, mode: a.mode } : null;
}

// ── Seed: the 3 current presets become DATA, not just CSS. ──────────────────
// These mirror tokens.css 1:1 (light :root, dark, signal) so the registry IS the
// source of truth; tokens.css remains the static default for no-JS artifacts.
// Built-ins are registered on import so a bare `import "./registry.js"` already
// has light/dark/signal available to applyTheme.

registerTheme({
  id: "light",
  name: "Paper (light)",
  extends: "light",
  tokens: {
    light: {
      "work-bg": "#f7f6f1", "work-surface": "#ffffff", "work-surface-soft": "#efede6",
      "work-border": "rgba(18, 19, 22, 0.13)", "work-border-strong": "rgba(18, 19, 22, 0.28)",
      "work-fg": "#121316", "work-fg-muted": "rgba(18, 19, 22, 0.6)", "work-fg-subtle": "rgba(18, 19, 22, 0.38)",
      "work-brand": "#13d943", "work-brand-soft": "rgba(19, 217, 67, 0.13)", "work-brand-ink": "#0a2413",
      "work-on-brand": "#07210f", "work-ring": "rgba(19, 217, 67, 0.5)",
      "work-ok": "#0fae38", "work-warn": "#b8861b", "work-err": "#c92f2f",
      "work-on-state": "#ffffff", "work-on-warn": "#1c1304",
      "work-ok-soft": "rgba(15, 174, 56, 0.14)", "work-warn-soft": "rgba(184, 134, 27, 0.14)", "work-err-soft": "rgba(201, 47, 47, 0.14)",
      "work-chip-blue": "#aecbf2", "work-chip-green": "#b6e2bd", "work-chip-peach": "#f3cfae", "work-chip-lavender": "#d4c9f0",
    },
    dark: {},
  },
  fonts: { sans: '"Geist", system-ui, -apple-system, sans-serif', mono: '"Geist Mono", "JetBrains Mono", ui-monospace, monospace', display: '"Franie", "Geist", sans-serif' },
});

registerTheme({
  id: "dark",
  name: "Ink (dark)",
  extends: "dark",
  tokens: {
    light: {},
    dark: {
      "work-bg": "#0a0d13", "work-surface": "#10151f", "work-surface-soft": "#161c27",
      "work-border": "#23262c", "work-border-strong": "#353a44",
      "work-fg": "#e9edf4", "work-fg-muted": "#9aa0a6", "work-fg-subtle": "#6b727c",
      "work-brand": "#3fe081", "work-brand-soft": "rgba(63, 224, 129, 0.14)", "work-brand-ink": "#d7ffe6",
      "work-on-brand": "#07210f", "work-ring": "rgba(63, 224, 129, 0.5)",
      "work-ok": "#4f9d6b", "work-warn": "#f5a524", "work-err": "#ef5350",
      "work-on-state": "#07210f", "work-on-warn": "#1c1304",
      "work-ok-soft": "rgba(79, 157, 107, 0.18)", "work-warn-soft": "rgba(245, 165, 36, 0.18)", "work-err-soft": "rgba(239, 83, 80, 0.18)",
    },
  },
});

registerTheme({
  id: "signal",
  name: "Signal",
  extends: "dark",
  tokens: {
    light: {},
    dark: {
      "work-bg": "#0a0d13", "work-surface": "#10151f", "work-surface-soft": "#161c27",
      "work-border": "#1c232f", "work-border-strong": "#2a3340",
      "work-fg": "#e9edf4", "work-fg-muted": "#8893a6", "work-fg-subtle": "#5b6573",
      "work-brand": "#3da9fc", "work-brand-soft": "rgba(61,169,252,0.14)", "work-on-brand": "#04121f",
      "work-ring": "rgba(61,169,252,0.5)",
      "work-radius": "2px", "work-radius-sm": "2px", "work-radius-lg": "3px", "work-radius-pill": "3px",
    },
  },
  fonts: { sans: '"Space Grotesk", system-ui, sans-serif', mono: '"IBM Plex Mono", ui-monospace, monospace', display: '"Space Grotesk", sans-serif' },
});
