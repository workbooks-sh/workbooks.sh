// <work-editor> — a themed code editor. The editing surface is the zero-dep FLOOR:
// a transparent <textarea> over a token-highlighted <pre> overlay, with a line-
// number gutter. Composition-as-source: the code IS the artifact's source, edited
// in place — emits `work-code-change {value}` on every edit.
//
// THE EDITOR-SWAP SEAM (now wired to CodeMirror 6):
//   The public API — the `value` property/attr, the `language`/`readonly` attrs, the
//   `work-code-change` event, and the `<work-editor>` tag — is the contract. The
//   editing surface itself is built by `_mountSurface()` / read+written via
//   `getValue()` / `setValue()`. The POWERED build (./codemirror-tier.js) overrides
//   ONLY those internals (mount a CodeMirror EditorView in the shadow root, read/
//   write its doc) behind the same public API; nothing that consumes <work-editor>
//   — including <work-repl> — changes. The floor is the lower rung of one ladder.
//
//   Tier resolution (mirrors work-chart): `engine="codemirror"|"floor"` attr or
//   `window.__WB_EDITOR_ENGINE__` force it; default "auto" prefers CodeMirror and
//   falls back to the floor INSTANTLY if the lazy CDN import fails (offline /
//   network-blocked / the gate's wasm proof). NO build step, pure ESM; CM is
//   lazy-loaded from a CDN (overridable via window.__WB_CODEMIRROR__), never bundled.
//
// Lit base: the surface chrome (gutter/overlay/textarea) is a Lit template. The
// highlighted overlay is trusted, already-escaped HTML (see highlight.js), bound
// with Lit's `unsafeHTML` directive — the escaping lives in the tokenizer, not the
// markup author. The textarea value is managed imperatively (a `ref`) so a re-render
// never disturbs the caret; Lit only re-renders the overlay/gutter via reactive
// state.
import { WbElement, html, css, define } from "../../core/element.js";
import { ref, createRef } from "lit/directives/ref.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { highlight, normalizeLang } from "./highlight.js";
import { loadCodeMirror, readEditorTokens, createEditorView } from "./codemirror-tier.js";

const VARIANTS = defineVariants({
  variant: { options: ["card", "inline"], default: "card" },
});

export class WorkEditor extends WbElement {
  static variants = VARIANTS;
  // language + readonly reflected so :host([...]) + re-render react; gutter toggles linenos.
  // `engine` = tier override (auto | codemirror | floor).
  static props = [...variantAttrs(VARIANTS), "language", "readonly", "gutter", "placeholder", "engine"];

  static properties = {
    ...WbElement.properties,
    // the highlighted overlay markup + the gutter line list — reactive state
    _highlighted: { state: true },
    _lines: { state: true },
    // which tier rendered: "floor" | "codemirror" — toggles the floor wrap vs CM host
    _tier: { state: true },
  };

  static styles = css`
    :host { display: block; font-family: var(--work-font-mono); }
    .wrap { position: relative; display: flex;
      border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-bg); box-shadow: var(--work-shadow-sm); overflow: hidden; }
    :host([variant="inline"]) .wrap { border: none; box-shadow: none; background: var(--work-surface-soft); }

    .gutter { flex: none; padding: var(--work-space-3) var(--work-space-2);
      text-align: right; user-select: none; color: var(--work-fg-subtle);
      font-size: var(--work-text-sm); line-height: 1.6;
      background: var(--work-surface-soft); border-right: 1px solid var(--work-border);
      font-variant-numeric: tabular-nums; min-width: 2.2em; }
    :host([gutter="off"]) .gutter { display: none; }

    /* the surface: textarea and overlay are layered, pixel-identical metrics */
    .surface { position: relative; flex: 1 1 auto; min-width: 0; }
    .overlay, textarea {
      margin: 0; padding: var(--work-space-3);
      font-family: var(--work-font-mono); font-size: var(--work-text-sm);
      line-height: 1.6; tab-size: 2; white-space: pre; overflow-wrap: normal;
      letter-spacing: 0; word-spacing: 0; border: 0; box-sizing: border-box;
    }
    .overlay { position: absolute; inset: 0; pointer-events: none; color: var(--work-fg);
      overflow: auto; }
    textarea {
      position: relative; width: 100%; height: 100%; min-height: var(--_minh, 8.6em);
      display: block; resize: vertical; background: transparent;
      color: transparent; caret-color: var(--work-fg);
      outline: none; overflow: auto; }
    textarea::selection { background: var(--work-brand-soft); color: var(--work-fg); }
    textarea::placeholder { color: var(--work-fg-subtle); }
    :host([readonly]) textarea { caret-color: transparent; }

    /* token classes — styled ONLY from --work-* */
    .tok-kw { color: var(--work-brand); font-weight: 600; }
    .tok-str { color: var(--work-ok); }
    .tok-num { color: var(--work-warn); }
    .tok-comment { color: var(--work-fg-subtle); font-style: italic; }

    textarea:focus-visible ~ .overlay,
    .wrap:focus-within { box-shadow: none; }
    .wrap:focus-within { border-color: var(--work-brand); box-shadow: 0 0 0 3px var(--work-ring); }

    /* the POWERED surface: a CodeMirror EditorView mounts INTO .cm-host. The
       chrome (border/radius/bg/focus-ring) is the floor's — CM only owns the inner
       content/gutter, themed from --work-* via the tier's EditorView.theme. */
    .cm-host { display: none; }
    :host([data-tier="codemirror"]) .cm-host {
      display: block;
      border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-bg); box-shadow: var(--work-shadow-sm); overflow: hidden;
    }
    :host([variant="inline"][data-tier="codemirror"]) .cm-host {
      border: none; box-shadow: none; background: var(--work-surface-soft);
    }
    .cm-host:focus-within { border-color: var(--work-brand); box-shadow: 0 0 0 3px var(--work-ring); }
    /* when CM owns the surface, the floor wrap is removed from the box entirely */
    :host([data-tier="codemirror"]) .wrap { display: none; }
    .cm-host .cm-editor { min-height: var(--_minh, 8.6em); }
  `;

  constructor() {
    super();
    this._taRef = createRef();
    this._ovRef = createRef();
    this._cmRef = createRef();
    this._highlighted = "";
    this._lines = "";
    this._tier = "floor";   // until the CM lazy-load resolves (or auto picks floor)
    this._cm = null;        // the codemirror-tier handle when mounted
  }

  // ---- public API (the swap-stable contract) ---------------------------------

  get value() { return this.getValue(); }
  set value(v) { this.setValue(v == null ? "" : String(v)); }

  get language() { return normalizeLang(this.attr("language", "js")); }
  set language(v) { this.setAttribute("language", v); }

  // ---- editing-surface seam (floor impl; CodeMirror overrides these) ---------

  /** Read the current text. CM tier: from the EditorView doc. Floor: the textarea. */
  getValue() {
    if (this._cm) return this._cm.getDoc();
    const ta = this._taRef.value;
    return ta ? ta.value : (this._pending != null ? this._pending : "");
  }

  /** Write text + emit change. CM tier: into the EditorView doc. Floor: the textarea. */
  setValue(v, { silent = false } = {}) {
    if (this._cm) {
      if (this._cm.getDoc() === v) return;
      this._suppressEmit = silent;          // the CM updateListener fires; gate emit
      this._cm.setDoc(v);
      this._suppressEmit = false;
      if (!silent) { /* updateListener already emitted */ }
      return;
    }
    const ta = this._taRef.value;
    if (!ta) { this._pending = v; return; }
    if (ta.value === v) return;
    ta.value = v;
    this._paint();
    if (!silent) this._emitChange();
  }

  // ---- tier resolution (mirrors work-chart's _tierChoice) --------------------
  //   - attribute engine="floor" | "codemirror" forces it (the gate drives this)
  //   - window.__WB_EDITOR_ENGINE__ = "floor" | "codemirror" is the host opt-out
  //   - default "auto": prefer CodeMirror, fall back to the floor if it can't load.
  _tierChoice() {
    const attr = this.attr("engine");
    if (attr === "floor" || attr === "codemirror") return attr;
    const host = typeof window !== "undefined" && window.__WB_EDITOR_ENGINE__;
    if (host === "floor" || host === "codemirror") return host;
    return "auto";
  }

  /** Build the editing surface. Resolves the tier: the FLOOR is wired immediately
   *  (it never blocks on a CDN and is the guaranteed render); when the tier is
   *  codemirror/auto, the CM EditorView is lazy-loaded and, on success, takes over
   *  the surface behind the same getValue/setValue/event contract. */
  _mountSurface() {
    this._mountFloor();
    const choice = this._tierChoice();
    if (choice !== "floor") this._mountCodeMirror(choice === "codemirror");
  }

  // The POWERED tier — CodeMirror 6, lazy-loaded from a CDN. On success it mounts an
  // EditorView in .cm-host (shadow-scoped styles), seeds it with the floor's current
  // value, and flips _tier → "codemirror" (CSS hides the floor wrap). On failure
  // (network-blocked / load error) the floor stays — forced "codemirror" still
  // degrades gracefully; the floor IS the guaranteed render (the wasm gate proves it).
  _mountCodeMirror(forced) {
    loadCodeMirror().then((CM) => {
      const host = this._cmRef.value;
      if (!host || this._cm) return;
      const tk = readEditorTokens(this);
      this._cm = createEditorView(CM, host, {
        doc: this.getValue(),
        language: this.language,
        readonly: this.boolAttr("readonly"),
        tk,
        root: this.shadowRoot,
        onChange: () => { if (!this._suppressEmit) this._emitChange(); },
      });
      this._tier = "codemirror";
      this.setAttribute("data-tier", "codemirror");
    }).catch((e) => {
      if (forced) console.warn("work-editor: CodeMirror failed to load, keeping floor", e);
      // floor remains; nothing to do.
    });
  }

  _mountFloor() {
    const ta = this._taRef.value;
    if (!ta) return;
    const sync = () => { this._paint(); this._emitChange(); };
    ta.addEventListener("input", sync);
    ta.addEventListener("scroll", () => {
      const ov = this._ovRef.value;
      if (ov) { ov.scrollTop = ta.scrollTop; ov.scrollLeft = ta.scrollLeft; }
    });
    // soft tab on Tab (floor nicety; CM handles this natively later)
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Tab" && !this.boolAttr("readonly")) {
        e.preventDefault();
        const s = ta.selectionStart, en = ta.selectionEnd;
        ta.value = ta.value.slice(0, s) + "  " + ta.value.slice(en);
        ta.selectionStart = ta.selectionEnd = s + 2;
        sync();
      }
    });
    // seed the textarea with the captured initial source, then paint the overlay
    if (ta.value === "" && this._initial) ta.value = this._initial;
    this._paint();
  }

  // ---- internals -------------------------------------------------------------

  // Recompute the highlight overlay + gutter into reactive state; Lit binds them
  // (overlay via unsafeHTML — the highlight HTML is escaped at the source).
  _paint() {
    const ta = this._taRef.value;
    if (!ta) return;
    const code = ta.value;
    // trailing newline keeps the overlay tall enough to match the textarea
    this._highlighted = highlight(code, this.language) + "\n";
    const n = code.split("\n").length;
    let g = "";
    for (let k = 1; k <= n; k++) g += k + "\n";
    this._lines = g;
  }

  _emitChange() {
    const value = this.getValue();
    this._pending = value;
    this.dispatchEvent(new CustomEvent("work-code-change", {
      detail: { value }, bubbles: true, composed: true,
    }));
  }

  connectedCallback() {
    // composition-as-source: capture slotted text ONCE before the base wipes it.
    if (this._initial == null) {
      this._initial = this.attr("value") != null ? this.attr("value") : (this.textContent || "");
      // strip a single leading newline authors get from writing the tag on its own line
      this._initial = this._initial.replace(/^\n/, "").replace(/\s+$/, "");
    }
    super.connectedCallback();
    // Re-theme the powered CM surface when the host flips data-work-theme — CM holds
    // computed token VALUES (not var()), so a flip must re-read + reconfigure. The
    // floor re-themes via the CSS cascade automatically; only CM needs the nudge.
    if (typeof MutationObserver !== "undefined") {
      this._themeObs = new MutationObserver(() => this._retheme());
      this._themeObs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-work-theme"] });
    }
  }

  disconnectedCallback() {
    if (this._themeObs) { this._themeObs.disconnect(); this._themeObs = null; }
    if (this._cm) { this._cm.destroy(); this._cm = null; }
    super.disconnectedCallback();
  }

  _retheme() {
    if (this._cm) this._cm.setTheme(readEditorTokens(this));
  }

  // Lit lifecycle: wire the surface once the template + textarea exist.
  firstUpdated() {
    this._mountSurface();
  }

  // Propagate language/readonly to the CM tier on every (re)render. CM reconfigure
  // is idempotent — re-applying the same grammar/readonly is a no-op — so we sync
  // unconditionally rather than diffing the reactive-property map (language is a
  // prototype getter, so it never lands in Lit's `changed` set). The floor reads
  // these straight off attributes in _paint()/render() and needs no propagation.
  updated() {
    if (!this._cm) return;
    if (this._cmLang !== this.language) { this._cmLang = this.language; this._cm.setLanguage(this.language); }
    const ro = this.boolAttr("readonly");
    if (this._cmRo !== ro) { this._cmRo = ro; this._cm.setReadonly(ro); }
  }

  render() {
    const ro = this.boolAttr("readonly");
    const ph = this.attr("placeholder", "");
    return html`
      <div class="wrap">
        <pre class="gutter" aria-hidden="true">${this._lines}</pre>
        <div class="surface">
          <textarea ${ref(this._taRef)} spellcheck="false" autocomplete="off"
            autocapitalize="off" wrap="off" ?readonly=${ro}
            placeholder=${ph}></textarea>
          <pre class="overlay" aria-hidden="true" ${ref(this._ovRef)}>${unsafeHTML(this._highlighted)}</pre>
        </div>
      </div>
      <div class="cm-host" ${ref(this._cmRef)}></div>`;
  }
}

define("work-editor", WorkEditor);
