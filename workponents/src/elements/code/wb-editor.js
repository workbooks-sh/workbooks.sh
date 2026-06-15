// <wb-editor> — a themed code editor. The editing surface is the zero-dep FLOOR:
// a transparent <textarea> over a token-highlighted <pre> overlay, with a line-
// number gutter. Composition-as-source: the code IS the artifact's source, edited
// in place — emits `wb-code-change {value}` on every edit.
//
// THE EDITOR-SWAP SEAM (for CodeMirror later):
//   The public API — the `value` property/attr, the `language` attr, the
//   `wb-code-change` event, and the `<wb-editor>` tag — is the contract. The
//   editing surface itself is built by `_mountSurface()` / read+written via
//   `getValue()` / `setValue()`. A powered build overrides ONLY those three
//   internals (mount a CodeMirror EditorView, read/write its doc) behind the same
//   public API; nothing that consumes <wb-editor> changes. The floor is a refusal
//   of nothing — it is the lower rung of one ladder. NO build step, pure ESM.
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { highlight, normalizeLang } from "./highlight.js";

const VARIANTS = defineVariants({
  variant: { options: ["card", "inline"], default: "card" },
});

export class WbEditor extends WbElement {
  static variants = VARIANTS;
  // language + readonly reflected so :host([...]) + re-render react; gutter toggles linenos.
  static props = [...variantAttrs(VARIANTS), "language", "readonly", "gutter", "placeholder"];

  static styles = `
    :host { display: block; font-family: var(--wb-font-mono); }
    .wrap { position: relative; display: flex;
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-bg); box-shadow: var(--wb-shadow-sm); overflow: hidden; }
    :host([variant="inline"]) .wrap { border: none; box-shadow: none; background: var(--wb-surface-soft); }

    .gutter { flex: none; padding: var(--wb-space-3) var(--wb-space-2);
      text-align: right; user-select: none; color: var(--wb-fg-subtle);
      font-size: var(--wb-text-sm); line-height: 1.6;
      background: var(--wb-surface-soft); border-right: 1px solid var(--wb-border);
      font-variant-numeric: tabular-nums; min-width: 2.2em; }
    :host([gutter="off"]) .gutter { display: none; }

    /* the surface: textarea and overlay are layered, pixel-identical metrics */
    .surface { position: relative; flex: 1 1 auto; min-width: 0; }
    .overlay, textarea {
      margin: 0; padding: var(--wb-space-3);
      font-family: var(--wb-font-mono); font-size: var(--wb-text-sm);
      line-height: 1.6; tab-size: 2; white-space: pre; overflow-wrap: normal;
      letter-spacing: 0; word-spacing: 0; border: 0; box-sizing: border-box;
    }
    .overlay { position: absolute; inset: 0; pointer-events: none; color: var(--wb-fg);
      overflow: auto; }
    textarea {
      position: relative; width: 100%; height: 100%; min-height: var(--_minh, 8.6em);
      display: block; resize: vertical; background: transparent;
      color: transparent; caret-color: var(--wb-fg);
      outline: none; overflow: auto; }
    textarea::selection { background: var(--wb-brand-soft); color: var(--wb-fg); }
    textarea::placeholder { color: var(--wb-fg-subtle); }
    :host([readonly]) textarea { caret-color: transparent; }

    /* token classes — styled ONLY from --wb-* */
    .tok-kw { color: var(--wb-brand); font-weight: 600; }
    .tok-str { color: var(--wb-ok); }
    .tok-num { color: var(--wb-warn); }
    .tok-comment { color: var(--wb-fg-subtle); font-style: italic; }

    textarea:focus-visible ~ .overlay,
    .wrap:focus-within { box-shadow: none; }
    .wrap:focus-within { border-color: var(--wb-brand); box-shadow: 0 0 0 3px var(--wb-ring); }
  `;

  // ---- public API (the swap-stable contract) ---------------------------------

  get value() { return this.getValue(); }
  set value(v) { this.setValue(v == null ? "" : String(v)); }

  get language() { return normalizeLang(this.attr("language", "js")); }
  set language(v) { this.setAttribute("language", v); }

  // ---- editing-surface seam (floor impl; CodeMirror overrides these) ---------

  /** Read the current text. (Floor: from the textarea.) */
  getValue() {
    const ta = this.shadowRoot && this.shadowRoot.querySelector("textarea");
    return ta ? ta.value : (this._pending != null ? this._pending : "");
  }

  /** Write text + re-highlight + emit change. (Floor: into the textarea.) */
  setValue(v, { silent = false } = {}) {
    const ta = this.shadowRoot && this.shadowRoot.querySelector("textarea");
    if (!ta) { this._pending = v; return; }
    if (ta.value === v) return;
    ta.value = v;
    this._paint();
    if (!silent) this._emitChange();
  }

  /** Build the editing surface into the shadow root. Floor = textarea+overlay. */
  _mountSurface() {
    const ta = this.shadowRoot.querySelector("textarea");
    if (!ta) return;
    const sync = () => { this._paint(); this._emitChange(); };
    ta.addEventListener("input", sync);
    ta.addEventListener("scroll", () => {
      const ov = this.shadowRoot.querySelector(".overlay");
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
    this._paint();
  }

  // ---- internals -------------------------------------------------------------

  _paint() {
    const ta = this.shadowRoot.querySelector("textarea");
    const ov = this.shadowRoot.querySelector(".overlay");
    const gut = this.shadowRoot.querySelector(".gutter");
    if (!ta || !ov) return;
    const code = ta.value;
    // trailing newline keeps the overlay tall enough to match the textarea
    ov.innerHTML = highlight(code, this.language) + "\n";
    if (gut) {
      const n = code.split("\n").length;
      let g = "";
      for (let k = 1; k <= n; k++) g += k + "\n";
      gut.textContent = g;
    }
  }

  _emitChange() {
    const value = this.getValue();
    this._pending = value;
    this.dispatchEvent(new CustomEvent("wb-code-change", {
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
    this._mountSurface();
  }

  render() {
    const ro = this.boolAttr("readonly") ? "readonly" : "";
    const ph = this.attr("placeholder", "");
    const initial = this._pending != null ? this._pending : (this._initial || "");
    const esc = initial.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    return `
      <div class="wrap">
        <pre class="gutter" aria-hidden="true"></pre>
        <div class="surface">
          <textarea spellcheck="false" autocomplete="off" autocapitalize="off"
            wrap="off" ${ro} placeholder="${ph.replace(/"/g, "&quot;")}">${esc}</textarea>
          <pre class="overlay" aria-hidden="true"></pre>
        </div>
      </div>`;
  }

  // The base re-renders on attr changes; re-mount the surface + repaint each time.
  update() {
    super.update();
    this._mountSurface();
  }
}

define("wb-editor", WbEditor);
