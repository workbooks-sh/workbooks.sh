// <wb-dropzone> — drag (or pick) files to add them to the drive.
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
//   <wb-dropzone accept="image/*,text/*" multiple></wb-dropzone>
//   el.addEventListener("wb-file-add", e => insertRows(e.detail.files));
//
// Attributes:
//   accept    a standard accept list passed to the file input
//   multiple  allow selecting more than one file
//   hash      when present, compute a sha256 content-hash per file (default on)
//   variant   framed | bare
//
// Events:
//   wb-file-add  { detail: { files: [{ name, type, size, modified, hash?, file }] } }
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

const VARIANTS = defineVariants({
  variant: { options: ["framed", "bare"], default: "framed" },
});

export class WbDropzone extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "accept", "multiple"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .zone { display: flex; flex-direction: column; align-items: center; justify-content: center;
      gap: var(--wb-space-2); padding: var(--wb-space-5); text-align: center; cursor: pointer;
      border: 1.5px dashed var(--wb-border-strong); border-radius: var(--wb-radius);
      background: var(--wb-surface); color: var(--wb-fg-muted);
      transition: border-color var(--wb-dur) var(--wb-ease), background var(--wb-dur) var(--wb-ease); }
    :host([variant="bare"]) .zone { background: transparent; }
    .zone:hover { border-color: var(--wb-brand); }
    .zone.over { border-color: var(--wb-brand); background: var(--wb-brand-soft); color: var(--wb-brand); }
    .zone:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    .glyph { font-size: 26px; }
    .label { font-size: var(--wb-text-sm); font-weight: 600; color: var(--wb-fg); }
    .hint { font-family: var(--wb-font-mono); font-size: 11px; color: var(--wb-fg-subtle); }
    input { display: none; }
  `;

  render() {
    const acc = this.attr("accept");
    return `<div class="zone" tabindex="0" role="button" aria-label="Add files">
      <span class="glyph">⤓</span>
      <span class="label"><slot>Drop files, or click to add</slot></span>
      <span class="hint">${acc ? esc(acc) : "any type"} · added as content-addressed rows</span>
      <input type="file" ${this.boolAttr("multiple") ? "multiple" : ""}${acc ? ` accept="${esc(acc)}"` : ""} />
    </div>`;
  }

  update() {
    super.update();
    const zone = this.shadowRoot.querySelector(".zone");
    const input = this.shadowRoot.querySelector("input");
    if (!zone || !input) return;
    zone.addEventListener("click", () => input.click());
    zone.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); input.click(); } });
    input.addEventListener("change", () => { this._ingest(input.files); input.value = ""; });
    zone.addEventListener("dragover", (e) => { e.preventDefault(); zone.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("over"));
    zone.addEventListener("drop", (e) => {
      e.preventDefault(); zone.classList.remove("over");
      this._ingest(e.dataTransfer?.files);
    });
  }

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
    this.dispatchEvent(new CustomEvent("wb-file-add", { detail: { files }, bubbles: true, composed: true }));
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

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

define("wb-dropzone", WbDropzone);
