// <work-editor> — a themed code editor. The editing surface is the zero-dep FLOOR:
// a transparent <textarea> over a token-highlighted <pre> overlay, with a line-
// number gutter. Composition-as-source: the code IS the artifact's source, edited
// in place — emits `work-code-change {value}` on every edit.
//
// THE EDITOR-SWAP SEAM (for CodeMirror later):
//   The public API — the `value` property/attr, the `language` attr, the
//   `work-code-change` event, and the `<work-editor>` tag — is the contract. The
//   editing surface itself is built by `_mountSurface()` / read+written via
//   `getValue()` / `setValue()`. A powered build overrides ONLY those three
//   internals (mount a CodeMirror EditorView, read/write its doc) behind the same
//   public API; nothing that consumes <work-editor> changes. The floor is a refusal
//   of nothing — it is the lower rung of one ladder. NO build step, pure ESM.
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

const VARIANTS = defineVariants({
  variant: { options: ["card", "inline"], default: "card" },
});

export class WorkEditor extends WbElement {
  static variants = VARIANTS;
  // language + readonly reflected so :host([...]) + re-render react; gutter toggles linenos.
  static props = [...variantAttrs(VARIANTS), "language", "readonly", "gutter", "placeholder"];

  static properties = {
    ...WbElement.properties,
    // the highlighted overlay markup + the gutter line list — reactive state
    _highlighted: { state: true },
    _lines: { state: true },
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
  `;

  constructor() {
    super();
    this._taRef = createRef();
    this._ovRef = createRef();
    this._highlighted = "";
    this._lines = "";
  }

  // ---- public API (the swap-stable contract) ---------------------------------

  get value() { return this.getValue(); }
  set value(v) { this.setValue(v == null ? "" : String(v)); }

  get language() { return normalizeLang(this.attr("language", "js")); }
  set language(v) { this.setAttribute("language", v); }

  // ---- editing-surface seam (floor impl; CodeMirror overrides these) ---------

  /** Read the current text. (Floor: from the textarea.) */
  getValue() {
    const ta = this._taRef.value;
    return ta ? ta.value : (this._pending != null ? this._pending : "");
  }

  /** Write text + re-highlight + emit change. (Floor: into the textarea.) */
  setValue(v, { silent = false } = {}) {
    const ta = this._taRef.value;
    if (!ta) { this._pending = v; return; }
    if (ta.value === v) return;
    ta.value = v;
    this._paint();
    if (!silent) this._emitChange();
  }

  /** Build the editing surface. Floor = textarea+overlay wired here once the Lit
   *  template has rendered (firstUpdated). CodeMirror overrides this hook. */
  _mountSurface() {
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
  }

  // Lit lifecycle: wire the surface once the template + textarea exist.
  firstUpdated() {
    this._mountSurface();
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
      </div>`;
  }
}

define("work-editor", WorkEditor);
