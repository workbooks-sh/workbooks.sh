// <document-import> — a token-only dropzone that imports a .docx into a sibling
// <document-view>. The docx → org/markdown conversion is the docx-io floor adapter;
// this element is just the affordance (drop / pick a file) wired to the target
// doc's importDocxBuffer(). Bind a target by `for="<document-view id>"`.
//
// Emits `document-import {ok, name, error?}` after each attempt. No color literals
// — every surface reads from --work-* (gate-a/design-lint clean).
import { WbElement, html, css, define } from "../../core/element.js";

export class WbDocImport extends WbElement {
  static props = ["for", "label"];

  static styles = css`
    :host { display: block; }
    .zone {
      display: flex; align-items: center; justify-content: center; gap: var(--work-space-2);
      padding: var(--work-space-4);
      border: 1.5px dashed var(--work-border-strong);
      border-radius: var(--work-radius);
      background: var(--work-surface);
      color: var(--work-fg-muted);
      font: 600 var(--work-text-sm) var(--work-font, system-ui);
      cursor: pointer;
      transition: border-color .15s, background .15s, color .15s;
    }
    .zone:hover, .zone[data-drag="1"] { border-color: var(--work-fg); color: var(--work-fg); }
    .zone[data-state="busy"] { opacity: .6; pointer-events: none; }
    .zone[data-state="err"] { border-color: var(--work-err); color: var(--work-err); }
    input { display: none; }
  `;

  connectedCallback() { super.connectedCallback(); this._state = "idle"; }

  _target() {
    const id = this.attr("for");
    if (id) return (this.getRootNode().getElementById?.(id)) || document.getElementById(id);
    // default: the next <document-view> sibling
    let n = this.nextElementSibling;
    while (n && n.tagName !== "DOCUMENT-VIEW") n = n.nextElementSibling;
    return n;
  }

  async _ingest(file) {
    const doc = this._target();
    if (!doc || typeof doc.importDocxBuffer !== "function") {
      this._fail(file?.name, "no target document-view");
      return;
    }
    this._state = "busy"; this.requestUpdate();
    try {
      const buf = await file.arrayBuffer();
      await doc.importDocxBuffer(buf);
      const ok = !doc._error;
      this._state = ok ? "idle" : "err"; this.requestUpdate();
      this.dispatchEvent(new CustomEvent("document-import", { bubbles: true, composed: true, detail: { ok, name: file.name, error: doc._error || undefined } }));
    } catch (e) {
      this._fail(file.name, String(e.message || e));
    }
  }

  _fail(name, error) {
    this._state = "err"; this.requestUpdate();
    this.dispatchEvent(new CustomEvent("document-import", { bubbles: true, composed: true, detail: { ok: false, name, error } }));
  }

  render() {
    const label = this.attr("label") || "Drop a .docx or click to import";
    return html`
      <label class="zone" data-state=${this._state || "idle"}
        @dragover=${(e) => { e.preventDefault(); e.currentTarget.dataset.drag = "1"; }}
        @dragleave=${(e) => { e.currentTarget.dataset.drag = "0"; }}
        @drop=${(e) => { e.preventDefault(); e.currentTarget.dataset.drag = "0"; const f = e.dataTransfer?.files?.[0]; if (f) this._ingest(f); }}>
        <span>${this._state === "busy" ? "Importing…" : this._state === "err" ? "Import failed — try again" : label}</span>
        <input type="file" accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
          @change=${(e) => { const f = e.target.files?.[0]; if (f) this._ingest(f); e.target.value = ""; }} />
      </label>
    `;
  }
}

define("document-import", WbDocImport);
