// <wb-file> — a single file card with an inline, type-aware preview.
//
// The files reinvention: a file is a content-addressed RECORD, so previewing it
// is a question of resolving its bytes and rendering them by `type` — image /
// audio / video play inline (video rides the wavelet path when the Host can
// transcode), text shows inline, anything else degrades to a typed icon +
// metadata. Content is resolved through the Host/Dock seam when docked (the
// nexus holds the content-addressed blob); standalone it falls back to a `src`
// URL or `text`, otherwise a typed placeholder. No bytes are ever required for
// the card to render — metadata alone is enough.
//
// Source resolution, in order:
//   • `src`  — a directly fetchable URL (image/audio/video/text by URL)
//   • `text` — inline text content (a code/markdown/csv snippet)
//   • `path` + a docked Host — content fetched via this.host (`/files/get`)
//   • otherwise — a typed placeholder + metadata (degraded but complete)
//
// Usage:
//   <wb-file name="logo.svg" type="image/svg+xml" src="./logo.svg"></wb-file>
//   <wb-file name="readme.md" type="text/markdown" text="# Hello"></wb-file>
//   <wb-file name="clip.mp4" type="video/mp4" path="blobs/abc" size="91234"></wb-file>
//
// Attributes:
//   name      file name (shown as the title)
//   type      mime/type or extension (drives the preview)
//   src       a fetchable URL for the content (image/audio/video/text)
//   text      inline text content
//   path      content key/path (resolved via the Host when docked)
//   hash      content-hash (shown in metadata)
//   size      byte size (shown in metadata)
//   modified  modified timestamp (shown in metadata)
//   variant   card | bare      (visual shell)
//   size-v    sm | md | lg      (preview height)  [reflected attr "density"]
//
// Events:
//   wb-file-open  { detail: { file } }   fired when the preview/title is opened
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { fileKind, kindGlyph, fmtBytes, fmtWhen, shortHash, extOf } from "./file-types.js";

const VARIANTS = defineVariants({
  variant: { options: ["card", "bare"], default: "card" },
  density: { options: ["sm", "md", "lg"], default: "md" },
});

export class WbFile extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "name", "type", "src", "text", "path", "hash", "size", "modified",
  ];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .card { border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); overflow: hidden; box-shadow: var(--wb-shadow-sm);
      display: flex; flex-direction: column; }
    :host([variant="bare"]) .card { border: none; box-shadow: none; background: transparent; }

    .head { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3); border-bottom: 1px solid var(--wb-border);
      background: var(--wb-surface-soft); }
    .badge { width: 26px; height: 26px; flex: none; display: grid; place-items: center;
      border-radius: var(--wb-radius-sm); font-size: 14px; background: var(--wb-surface); color: var(--wb-fg-muted); }
    .badge[data-kind="image"] { background: var(--wb-chip-lavender); color: var(--wb-brand-ink); }
    .badge[data-kind="video"] { background: var(--wb-chip-peach);    color: var(--wb-brand-ink); }
    .badge[data-kind="audio"] { background: var(--wb-chip-green);    color: var(--wb-brand-ink); }
    .badge[data-kind="text"]  { background: var(--wb-chip-blue);     color: var(--wb-brand-ink); }
    .title { font-weight: 600; font-size: var(--wb-text); letter-spacing: -.005em;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; }
    .title:hover { color: var(--wb-brand); }
    .grow { flex: 1; }
    .typetag { font-family: var(--wb-font-mono); font-size: 10px; text-transform: uppercase;
      letter-spacing: .04em; color: var(--wb-fg-subtle); }

    /* preview stage */
    .stage { position: relative; display: flex; align-items: center; justify-content: center;
      background:
        repeating-conic-gradient(color-mix(in srgb, var(--wb-fg) 4%, transparent) 0% 25%, transparent 0% 50%) 50% / 20px 20px,
        var(--wb-bg);
      min-height: var(--_h, 220px); max-height: var(--_h, 220px); overflow: hidden; }
    :host([density="sm"]) .stage { --_h: 140px; }
    :host([density="lg"]) .stage { --_h: 340px; }

    .stage img { max-width: 100%; max-height: var(--_h, 220px); object-fit: contain; display: block; }
    .stage video { max-width: 100%; max-height: var(--_h, 220px); background: #000; }
    .stage audio { width: 90%; }
    .audio-wrap { display: flex; flex-direction: column; align-items: center; gap: var(--wb-space-3); width: 100%; padding: var(--wb-space-4); }
    .audio-glyph { font-size: 38px; color: var(--wb-brand); }

    .textview { width: 100%; height: var(--_h, 220px); margin: 0; overflow: auto;
      padding: var(--wb-space-3); box-sizing: border-box;
      font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); line-height: 1.5;
      color: var(--wb-fg); background: var(--wb-surface); white-space: pre-wrap; word-break: break-word; text-align: left; }

    .placeholder { display: flex; flex-direction: column; align-items: center; gap: var(--wb-space-2);
      color: var(--wb-fg-muted); padding: var(--wb-space-5); text-align: center; }
    .ph-glyph { width: 64px; height: 64px; display: grid; place-items: center; font-size: 30px;
      border-radius: var(--wb-radius); background: var(--wb-surface); color: var(--wb-fg-muted);
      border: 1px solid var(--wb-border); }
    .ph-glyph[data-kind="image"] { background: var(--wb-chip-lavender); color: var(--wb-brand-ink); }
    .ph-glyph[data-kind="video"] { background: var(--wb-chip-peach);    color: var(--wb-brand-ink); }
    .ph-glyph[data-kind="audio"] { background: var(--wb-chip-green);    color: var(--wb-brand-ink); }
    .ph-glyph[data-kind="text"]  { background: var(--wb-chip-blue);     color: var(--wb-brand-ink); }
    .ph-ext { font-family: var(--wb-font-mono); font-size: 11px; }
    .ph-note { font-size: var(--wb-text-sm); }
    .status { color: var(--wb-fg-muted); font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); padding: var(--wb-space-4); }
    .status.err { color: var(--wb-err); white-space: pre-wrap; }

    /* metadata footer */
    .meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
      gap: var(--wb-space-1) var(--wb-space-4); padding: var(--wb-space-2) var(--wb-space-3);
      border-top: 1px solid var(--wb-border); }
    .m { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
    .m .k { font-family: var(--wb-font-mono); font-size: 9px; text-transform: uppercase;
      letter-spacing: .05em; color: var(--wb-fg-subtle); }
    .m .v { font-size: var(--wb-text-sm); color: var(--wb-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .m .v.mono { font-family: var(--wb-font-mono); font-size: 11px; color: var(--wb-fg-muted); }
    .docked { font-family: var(--wb-font-mono); font-size: 9px; }
  `;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._objUrl = null;   // a blob URL we created (revoked on change/disconnect)
      this._resolved = null; // {url} | {text} from the Host
      this._error = null;
      this._busy = false;
    }
    super.connectedCallback();
    this._resolveContent();
  }

  disconnectedCallback() { this._revoke(); }

  attributeChangedCallback(name) {
    if (!this._connected) return;
    if (["src", "text", "path", "type"].includes(name)) this._resolveContent();
    else this.update();
  }

  _revoke() { if (this._objUrl) { try { URL.revokeObjectURL(this._objUrl); } catch {} this._objUrl = null; } }

  get _kind() { return fileKind(this.attr("type"), this.attr("name")); }

  /** Resolve previewable content. Direct src/text need nothing; a `path` is
   *  fetched via the Host when a runtime is docked. Never blocks the card. */
  async _resolveContent() {
    this._revoke();
    this._resolved = null;
    this._error = null;
    // Direct URL / inline text — no resolution needed.
    if (this.attr("src") || this.attr("text") != null) { this.update(); return; }
    const path = this.attr("path");
    if (!path) { this.update(); return; }       // metadata-only → typed placeholder
    if (!this.host.available("files")) { this.update(); return; } // standalone, no Host
    // Docked: ask the Host for the content-addressed blob.
    this._busy = true; this.update();
    try {
      const out = await this.host.request("/files/get", { body: { path, hash: this.attr("hash") } });
      if (out && out.url) this._resolved = { url: out.url };
      else if (out && out.text != null) this._resolved = { text: out.text };
      else if (out && out.dataUrl) this._resolved = { url: out.dataUrl };
    } catch (e) {
      this._error = String((e && e.message) || e);
    }
    this._busy = false;
    this.update();
  }

  /** The URL to render media from (direct src or a Host-resolved blob). */
  _mediaUrl() { return this.attr("src") || (this._resolved && this._resolved.url) || null; }
  /** The text to render (inline attr or Host-resolved). */
  _textContent() {
    const t = this.attr("text");
    if (t != null) return t;
    return this._resolved && this._resolved.text != null ? this._resolved.text : null;
  }

  render() {
    const name = this.attr("name") || "Untitled";
    const type = this.attr("type") || "";
    const kind = this._kind;
    const ext = extOf(name) || extOf(type);
    return `<div class="card">
      <div class="head">
        <span class="badge" data-kind="${kind}">${kindGlyph(kind)}</span>
        <span class="title" title="${esc(name)}">${esc(name)}</span>
        <span class="grow"></span>
        <span class="typetag">${esc(type || ext || kind)}</span>
      </div>
      <div class="stage">${this._renderPreview(kind)}</div>
      ${this._renderMeta()}
    </div>`;
  }

  _renderPreview(kind) {
    if (this._busy) return `<div class="status">Resolving content…</div>`;
    if (this._error) return `<div class="status err">Could not load — ${esc(this._error)}</div>`;
    const url = this._mediaUrl();
    const text = this._textContent();

    if (kind === "image" && url) return `<img src="${esc(url)}" alt="${esc(this.attr("name") || "")}" />`;
    if (kind === "video" && url) return `<video src="${esc(url)}" controls preload="metadata"></video>`;
    if (kind === "audio" && url) {
      return `<div class="audio-wrap"><span class="audio-glyph">${kindGlyph("audio")}</span>
        <audio src="${esc(url)}" controls></audio></div>`;
    }
    if ((kind === "text" || kind === "code") && text != null) {
      const clipped = text.length > 8000 ? text.slice(0, 8000) + "\n…" : text;
      return `<pre class="textview">${esc(clipped)}</pre>`;
    }
    // text/code with a URL but no inline content, and no Host text → placeholder
    return this._renderPlaceholder(kind);
  }

  _renderPlaceholder(kind) {
    const ext = extOf(this.attr("name")) || extOf(this.attr("type"));
    const path = this.attr("path");
    const note = path && !this.host.available("files")
      ? "Content lives in the nexus — dock a runtime to preview."
      : (kind === "video"
          ? "Preview / transcode via the wavelet path when docked."
          : "No preview — metadata only.");
    return `<div class="placeholder">
      <span class="ph-glyph" data-kind="${kind}">${kindGlyph(kind)}</span>
      ${ext ? `<span class="ph-ext">.${esc(ext)}</span>` : ""}
      <span class="ph-note">${esc(note)}</span>
    </div>`;
  }

  _renderMeta() {
    const items = [];
    const type = this.attr("type");
    const size = this.attr("size");
    const modified = this.attr("modified");
    const hash = this.attr("hash");
    const path = this.attr("path");
    if (type) items.push(["Type", esc(type), false]);
    if (size != null && size !== "") items.push(["Size", esc(fmtBytes(size)), true]);
    if (modified) items.push(["Modified", esc(fmtWhen(modified)), false]);
    if (hash) items.push(["Content hash", esc(shortHash(hash)), true]);
    if (path) items.push(["Path", esc(path), true]);
    if (!items.length) return "";
    const docked = path
      ? `<span class="docked" style="color:var(${this.host.available("files") ? "--wb-ok" : "--wb-fg-subtle"})">${this.host.available("files") ? "● docked" : "○ standalone"}</span>`
      : "";
    return `<div class="meta">${items.map(([k, v, mono]) =>
      `<span class="m"><span class="k">${k}</span><span class="v${mono ? " mono" : ""}" title="${v}">${v}</span></span>`).join("")}
      ${docked ? `<span class="m"><span class="k">Source</span><span class="v">${docked}</span></span>` : ""}
    </div>`;
  }

  update() {
    super.update();
    const open = () => this.dispatchEvent(new CustomEvent("wb-file-open", {
      detail: { file: this._file() }, bubbles: true, composed: true }));
    this.shadowRoot.querySelector(".title")?.addEventListener("click", open);
    this.shadowRoot.querySelector("img")?.addEventListener("click", open);
  }

  _file() {
    const o = {};
    for (const a of ["name", "type", "src", "path", "hash", "size", "modified"]) {
      const v = this.attr(a); if (v != null) o[a] = v;
    }
    return o;
  }
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

define("wb-file", WbFile);
