// code · the POWERED tier — CodeMirror 6 behind the <work-editor> floor.
//
// The floor (work-editor.js) is a zero-dependency editing surface: a transparent
// <textarea> over a token-highlighted <pre> overlay, themed entirely from --work-*.
// This module is the powered alternative: a real CodeMirror 6 EditorView mounted in
// the element's SHADOW root, wired to the SAME public API — `getValue`/`setValue`,
// the `value`/`language`/`readonly` props, and the `work-code-change` event. Only
// the editing surface changes, never the contract; everything consuming
// <work-editor> (incl. <work-repl>) inherits the upgrade unchanged.
//
// Lazy-loaded from a CDN ESM at runtime (mirrors plot-tier / sqlite-wasm / wavelet):
// nothing is bundled, no dep is installed. `loadCodeMirror()` is a single-flight
// import() that resolves to the CM namespaces we need (view/state/commands + a
// language pack), overridable via `window.__WB_CODEMIRROR__` (tests / offline hosts
// inject their own). If the import fails (network-blocked, the gate's wasm/floor
// proof), the caller silently falls back to the floor textarea+highlight.
//
// THEMING (gate-a, token-leak): CM ships its own default colors + injects its own
// styles. We never let a literal leak — every color/font CM paints is READ from the
// element's computed --work-* tokens (readEditorTokens) and fed into an
// EditorView.theme + a HighlightStyle. Flip the host theme, re-read, re-theme → the
// editor re-themes light/dark/signal exactly like the floor.
//
// SCOPE (gate-b): CM6 supports shadow-root hosting — we pass `root: shadowRoot` to
// the EditorView so CM injects its <style> into the SHADOW root (adopted by CM into
// the provided root), NOT document.head. Nothing global is polluted.

// CDN ESM endpoints. Each is a single-flight import; overridable wholesale via
// window.__WB_CODEMIRROR__ (a pre-resolved bundle the tests/offline hosts inject).
const CDN = {
  view:       "https://esm.sh/@codemirror/view@6",
  state:      "https://esm.sh/@codemirror/state@6",
  commands:   "https://esm.sh/@codemirror/commands@6",
  language:   "https://esm.sh/@codemirror/language@6",
  langJs:     "https://esm.sh/@codemirror/lang-javascript@6",
  langRust:   "https://esm.sh/@codemirror/lang-rust@6",
  langPython: "https://esm.sh/@codemirror/lang-python@6",
  langJson:   "https://esm.sh/@codemirror/lang-json@6",
  langCss:    "https://esm.sh/@codemirror/lang-css@6",
  langHtml:   "https://esm.sh/@codemirror/lang-html@6",
  lezerHl:    "https://esm.sh/@lezer/highlight@1",
};

let _cmPromise = null;

/**
 * Single-flight lazy import of the CodeMirror 6 bundle. Resolves to a namespace
 * object: { EditorView, EditorState, keymap, defaultKeymap, history, historyKeymap,
 * lineNumbers, HighlightStyle, syntaxHighlighting, tags, langFor }.
 * Overridable for tests / offline hosts via `window.__WB_CODEMIRROR__`.
 * Throws (rejects) when the chunk can't load — the caller falls back to the floor.
 */
export function loadCodeMirror() {
  const override = typeof window !== "undefined" && window.__WB_CODEMIRROR__;
  if (override) return Promise.resolve(override);
  if (!_cmPromise) {
    _cmPromise = (async () => {
      const [view, state, commands, language, lezerHl] = await Promise.all([
        import(/* @vite-ignore */ CDN.view),
        import(/* @vite-ignore */ CDN.state),
        import(/* @vite-ignore */ CDN.commands),
        import(/* @vite-ignore */ CDN.language),
        import(/* @vite-ignore */ CDN.lezerHl),
      ]);
      // language packs load on demand by tag — only what the editor asks for.
      const langFor = makeLangLoader();
      return {
        EditorView: view.EditorView,
        keymap: view.keymap,
        lineNumbers: view.lineNumbers,
        EditorState: state.EditorState,
        Compartment: state.Compartment,
        defaultKeymap: commands.defaultKeymap,
        history: commands.history,
        historyKeymap: commands.historyKeymap,
        indentWithTab: commands.indentWithTab,
        HighlightStyle: language.HighlightStyle,
        syntaxHighlighting: language.syntaxHighlighting,
        indentUnit: language.indentUnit,
        tags: lezerHl.tags,
        langFor,
      };
    })().catch((e) => {
      _cmPromise = null; // allow a later retry
      throw e;
    });
  }
  return _cmPromise;
}

// Map a normalized work-editor language → a single-flight CM language extension
// loader. Unknown / plain languages resolve to `null` (no language extension —
// CM still edits text, just without grammar highlighting).
function makeLangLoader() {
  const cache = new Map();
  const defs = {
    js: () => import(/* @vite-ignore */ CDN.langJs).then((m) => m.javascript({ jsx: true, typescript: true })),
    ts: () => import(/* @vite-ignore */ CDN.langJs).then((m) => m.javascript({ jsx: true, typescript: true })),
    rust: () => import(/* @vite-ignore */ CDN.langRust).then((m) => m.rust()),
    python: () => import(/* @vite-ignore */ CDN.langPython).then((m) => m.python()),
    py: () => import(/* @vite-ignore */ CDN.langPython).then((m) => m.python()),
    json: () => import(/* @vite-ignore */ CDN.langJson).then((m) => m.json()),
    css: () => import(/* @vite-ignore */ CDN.langCss).then((m) => m.css()),
    html: () => import(/* @vite-ignore */ CDN.langHtml).then((m) => m.html()),
  };
  return (lang) => {
    const def = defs[lang];
    if (!def) return Promise.resolve(null);
    if (!cache.has(lang)) cache.set(lang, def().catch(() => null));
    return cache.get(lang);
  };
}

// Read the resolved --work-* token VALUES off the element (computed style). CM gets
// concrete colors/fonts, never `var(--work-*)` strings (CM writes them into its own
// generated stylesheet, where the var() context can differ). Reading the computed
// value locks CM's paint to the active theme — flip the theme, re-read, re-apply →
// the editor re-themes (the flip-delta gate passes). Syntax colors mirror the
// floor's `.tok-*` classes exactly (brand=keyword, ok=string, warn=number,
// fg-subtle=comment) so floor↔CM is the same palette.
export function readEditorTokens(el) {
  const cs = getComputedStyle(el);
  const v = (name, fallback) => (cs.getPropertyValue(name).trim() || fallback);
  return {
    fg:         v("--work-fg", "#121316"),
    fgSubtle:   v("--work-fg-subtle", "rgba(18,19,22,0.38)"),
    bg:         v("--work-bg", "#ffffff"),
    surfaceSoft: v("--work-surface-soft", "#f4f4f3"),
    border:     v("--work-border", "rgba(18,19,22,0.13)"),
    selection:  v("--work-brand-soft", "rgba(19,217,67,0.18)"),
    ring:       v("--work-ring", "rgba(19,217,67,0.4)"),
    caret:      v("--work-fg", "#121316"),
    fontMono:   v("--work-font-mono", "ui-monospace, monospace"),
    textSm:     v("--work-text-sm", "12.5px"),
    // syntax — the SAME token roles the floor highlighter uses
    kw:      v("--work-brand", "#13d943"),
    str:     v("--work-ok", "#0fae38"),
    num:     v("--work-warn", "#b8861b"),
    comment: v("--work-fg-subtle", "rgba(18,19,22,0.38)"),
  };
}

/**
 * Build the CM extensions that paint the editor entirely from `tk`
 * (readEditorTokens). Returns an array of extensions: an EditorView.theme (chrome:
 * bg/fg/gutter/selection/caret/focus-ring) + a token-driven syntaxHighlighting.
 */
export function buildTheme(CM, tk) {
  const theme = CM.EditorView.theme(
    {
      "&": {
        color: tk.fg,
        backgroundColor: "transparent",
        fontFamily: tk.fontMono,
        fontSize: tk.textSm,
      },
      ".cm-content": { caretColor: tk.caret, padding: "12px 0" },
      ".cm-line": { padding: "0 12px" },
      "&.cm-focused": { outline: "none" },
      "&.cm-focused .cm-cursor": { borderLeftColor: tk.caret },
      ".cm-cursor": { borderLeftColor: tk.caret },
      "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {
        backgroundColor: tk.selection,
      },
      ".cm-gutters": {
        backgroundColor: tk.surfaceSoft,
        color: tk.fgSubtle,
        borderRight: "1px solid " + tk.border,
        fontVariantNumeric: "tabular-nums",
      },
      ".cm-activeLineGutter": { backgroundColor: "transparent" },
      ".cm-activeLine": { backgroundColor: "transparent" },
      ".cm-foldPlaceholder": { backgroundColor: "transparent", color: tk.fgSubtle },
      ".cm-scroller": { fontFamily: tk.fontMono, lineHeight: "1.6" },
    },
    { dark: false },
  );

  const hl = CM.HighlightStyle.define([
    { tag: CM.tags.keyword, color: tk.kw, fontWeight: "600" },
    { tag: [CM.tags.controlKeyword, CM.tags.moduleKeyword, CM.tags.definitionKeyword], color: tk.kw, fontWeight: "600" },
    { tag: [CM.tags.string, CM.tags.special(CM.tags.string)], color: tk.str },
    { tag: [CM.tags.number, CM.tags.bool, CM.tags.atom], color: tk.num },
    { tag: [CM.tags.comment, CM.tags.lineComment, CM.tags.blockComment], color: tk.comment, fontStyle: "italic" },
    { tag: [CM.tags.function(CM.tags.variableName), CM.tags.function(CM.tags.propertyName)], color: tk.fg },
    { tag: CM.tags.typeName, color: tk.fg },
  ]);

  return [theme, CM.syntaxHighlighting(hl)];
}

/**
 * Create + mount a CodeMirror EditorView in `parent` (the element's shadow root,
 * or a host node inside it). Wires the doc to `opts.doc`, sets language/readonly,
 * paints from `opts.tk`, and calls `opts.onChange(value)` on every doc edit.
 *
 * Returns { view, setDoc, setLanguage, setReadonly, setTheme, destroy } — the
 * imperative surface work-editor's getValue/setValue/_mountSurface drive. Language
 * + readonly + theme each live in a Compartment so they reconfigure without losing
 * the doc/selection/history (theme re-applies on every host theme flip).
 *
 * @param CM    the loaded CodeMirror namespace (loadCodeMirror())
 * @param parent  ShadowRoot (root for CM's injected styles) or an element in it
 * @param opts  { doc, language, readonly, tk, onChange, root }
 */
export function createEditorView(CM, parent, opts) {
  const langComp = new CM.Compartment();
  const roComp = new CM.Compartment();
  const themeComp = new CM.Compartment();
  const root = opts.root || parent.getRootNode();

  const updateListener = CM.EditorView.updateListener.of((vu) => {
    if (vu.docChanged && typeof opts.onChange === "function") {
      opts.onChange(vu.state.doc.toString());
    }
  });

  const baseExtensions = [
    CM.lineNumbers(),
    CM.history(),
    CM.keymap.of([...CM.defaultKeymap, ...CM.historyKeymap, CM.indentWithTab]),
    CM.indentUnit.of("  "),
    CM.EditorState.tabSize.of(2),
    CM.EditorView.lineWrapping,
    langComp.of([]),
    roComp.of([
      CM.EditorState.readOnly.of(!!opts.readonly),
      CM.EditorView.editable.of(!opts.readonly),
    ]),
    themeComp.of(buildTheme(CM, opts.tk)),
    updateListener,
  ];

  const state = CM.EditorState.create({
    doc: opts.doc || "",
    extensions: baseExtensions,
  });

  const view = new CM.EditorView({
    state,
    parent,
    // CM6 honors a `root` so its dynamically-injected styles land in the shadow
    // root's adopted stylesheet, not document.head (scope gate).
    root,
  });

  // load + apply the language grammar asynchronously (no language = plain text)
  const applyLanguage = (lang) => {
    CM.langFor(lang).then((ext) => {
      if (!view.dom.isConnected && !parent.contains(view.dom)) return;
      view.dispatch({ effects: langComp.reconfigure(ext ? [ext] : []) });
    });
  };
  applyLanguage(opts.language);

  return {
    view,
    setDoc(text) {
      const cur = view.state.doc.toString();
      if (cur === text) return;
      // selection clamps automatically. work-editor decides whether to re-emit
      // work-code-change (its own `silent` flag) — the updateListener always fires.
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
      });
    },
    getDoc() { return view.state.doc.toString(); },
    setLanguage(lang) { applyLanguage(lang); },
    setReadonly(ro) {
      view.dispatch({
        effects: roComp.reconfigure([
          CM.EditorState.readOnly.of(!!ro),
          CM.EditorView.editable.of(!ro),
        ]),
      });
    },
    setTheme(tk) {
      view.dispatch({ effects: themeComp.reconfigure(buildTheme(CM, tk)) });
    },
    destroy() { view.destroy(); },
  };
}
