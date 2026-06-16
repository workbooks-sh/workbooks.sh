// <work-dropzone> — drag (or pick) files to add them to the drive.
//
// Sharpens the files reinvention: adding a file = inserting a CONTENT-ADDRESSED
// ROW. This element doesn't write — it normalizes a drop/pick into file records
// (name, type, size, lastModified, and the File handle) and emits them; the page
// decides whether to register() them into the engine (standalone) or push the
// blob to the nexus via the Host (docked). It computes a content-hash (SHA-256
// over the bytes via SubtleCrypto when available) so the emitted record carries
// the address the rest of the domain keys on.
//
// Usage:
//   <work-dropzone accept="image/*,text/*" multiple></work-dropzone>
//   el.addEventListener("work-file-add", e => insertRows(e.detail.files));
//
// Attributes:
//   accept    a standard accept list passed to the file input
//   multiple  allow selecting more than one file
//   hash      when present, compute a sha256 content-hash per file (default on)
//   variant   framed | bare
//
// Events:
//   work-file-add  { detail: { files: [{ name, type, size, modified, hash?, file }] } }
import { WbElement, html, css, define } from "../../core/element.js";
import { ref, createRef } from "lit/directives/ref.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

const VARIANTS = defineVariants({
  variant: { options: ["framed", "bare"], default: "framed" },
});

export class WbDropzone extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "accept", "multiple"];

  static get observedAttributes() { return this.props; }

  attributeChangedCallback(name, old, val) {
    // Reads accept/multiple via this.attr() in render(); drives its own repaint.
    if (this._init) this.requestUpdate();
  }

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .zone { display: flex; flex-direction: column; align-items: center; justify-content: center;
      gap: var(--work-space-2); padding: var(--work-space-5); text-align: center; cursor: pointer;
      border: 1.5px dashed var(--work-border-strong); border-radius: var(--work-radius);
      background: var(--work-surface); color: var(--work-fg-muted);
      transition: border-color var(--work-dur) var(--work-ease), background var(--work-dur) var(--work-ease); }
    :host([variant="bare"]) .zone { background: transparent; }
    .zone:hover { border-color: var(--work-brand); }
    .zone.over { border-color: var(--work-brand); background: var(--work-brand-soft); color: var(--work-brand); }
    .zone:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); }
    .glyph { font-size: var(--work-glyph); }
    .label { font-size: var(--work-text-sm); font-weight: 600; color: var(--work-fg); }
    .hint { font-family: var(--work-font-mono); font-size: var(--work-text-xs); color: var(--work-fg-subtle); }
    input { display: none; }
  `;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._over = false;
      this._inputRef = createRef();
    }
    super.connectedCallback();
  }

  render() {
    const acc = this.attr("accept");
    return html`<div class="zone ${this._over ? "over" : ""}" tabindex="0" role="button" aria-label="Add files"
      @click=${this._pick} @keydown=${this._onKey}
      @dragover=${this._onDragover} @dragleave=${this._onDragleave} @drop=${this._onDrop}>
      <span class="glyph">⤓</span>
      <span class="label"><slot>Drop files, or click to add</slot></span>
      <span class="hint">${acc || "any type"} · added as content-addressed rows</span>
      <input ${ref(this._inputRef)} type="file" name="files" aria-label="Choose files"
        ?multiple=${this.boolAttr("multiple")} accept=${acc ?? ""} @change=${this._onChange} />
    </div>`;
  }

  _pick() { this._inputRef.value?.click(); }
  _onKey(e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); this._pick(); } }
  _onChange(e) { const input = e.target; this._ingest(input.files); input.value = ""; }
  _onDragover(e) { e.preventDefault(); this._over = true; this.requestUpdate(); }
  _onDragleave() { this._over = false; this.requestUpdate(); }
  _onDrop(e) { e.preventDefault(); this._over = false; this.requestUpdate(); this._ingest(e.dataTransfer?.files); }

  async _ingest(fileList) {
    const arr = [...(fileList || [])];
    if (!arr.length) return;
    const wantHash = !this.hasAttribute("hash") || this.attr("hash") !== "false";
    const files = await Promise.all(arr.map(async (f) => {
      const rec = {
        name: f.name, type: f.type || "", size: f.size,
        modified: f.lastModified ? new Date(f.lastModified).toISOString() : null, file: f,
      };
      if (wantHash) { try { rec.hash = await sha256(f); } catch {} }
      return rec;
    }));
    this.dispatchEvent(new CustomEvent("work-file-add", { detail: { files }, bubbles: true, composed: true }));
  }
}

/** SHA-256 of a File's bytes → "sha256:<hex>" (the content address). */
async function sha256(file) {
  const subtle = (typeof crypto !== "undefined" && crypto.subtle) || null;
  if (!subtle) throw new Error("no SubtleCrypto");
  const buf = await file.arrayBuffer();
  const digest = await subtle.digest("SHA-256", buf);
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return "sha256:" + hex;
}

define("work-dropzone", WbDropzone);
