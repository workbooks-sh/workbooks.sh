// <work-doc> — renders an org/markdown document directly from its source. The
// reinvention: the document IS its source (preview ≡ source) — there is no
// separate document model, so the same bytes an agent or cursor edits are what
// renders. Source comes from a `src` attr (a URL or inline) or the element's
// own inner text.
//
// Standalone fidelity: a dependency-free markdown + basic-org renderer
// (./render.js) — headings, lists, code, emphasis, links, tables, blockquotes,
// rules, checkboxes, and org TODO pills + tags. For FULL org fidelity (property
// drawers, footnotes, citations, #+EXEC component blocks, exact orgize parity)
// a wired Host routes rendering through the runtime — the same
// pipeline desktop/src/lib/org-renderer uses; this element reaches it via
// `this.host` when the `kernel` capability is available, and falls back to the
// standalone renderer otherwise.
//
// Live cells: fenced ```sql / ```polars / ```py / ```js / ```chart blocks (and
// the org #+begin_src equivalents) become <work-doc-cell> elements — first-class
// computed blocks, the docs-domain differentiator.
//
// Cross-element: emits `work-doc:rendered` with the parsed outline, so a sibling
// <work-doc-outline for="…"> stays auto-synced.
import { WbElement, html, css, define } from "../../core/element.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";
import { renderDoc, parseOutline } from "./render.js";
import { PROSE_CSS } from "./prose.js";
import "./wb-doc-cell.js";

let _cellSeq = 0;

export class WbDoc extends WbElement {
  static props = ["src", "format"];

  static styles = css`
    :host { display: block; }
    .doc { max-width: 76ch; margin: 0 auto; }
    .loading, .error { color: var(--work-fg-muted); font-family: var(--work-font); padding: var(--work-space-4); }
    .error { color: var(--work-err); }
    ${PROSE_CSS}
  `;

  connectedCallback() {
    if (this._source == null) this._source = this.attr("src") ? null : this.textContent;
    super.connectedCallback();
    if (this.attr("src")) this._loadSrc(this.attr("src"));
  }

  async _loadSrc(url) {
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`${res.status} ${url}`);
      // docx is an I/O adapter on top of the org/markdown source: a .docx src is
      // imported to that source, then rendered by the normal path. Detect by the
      // URL extension OR the ZIP container magic (PK…) so a docx served without a
      // .docx suffix still routes correctly.
      const buf = await res.arrayBuffer();
      const isDocx = /\.docx(\?|#|$)/i.test(url) || (await this._isDocxBuf(buf));
      this._source = isDocx ? await this._importDocx(buf) : new TextDecoder().decode(buf);
      this.requestUpdate();
    } catch (e) {
      this._error = String(e.message || e);
      this.requestUpdate();
    }
  }

  async _isDocxBuf(buf) {
    const { looksLikeDocx } = await import("./docx-io.js");
    return looksLikeDocx(buf);
  }

  async _importDocx(buf) {
    const { importDocx } = await import("./docx-io.js");
    return importDocx(buf);
  }

  /**
   * Set the document from a .docx ArrayBuffer (import adapter). Renders the result
   * as org/markdown through the normal path. Emits `work-doc-export` on completion
   * is NOT this path — see export() — but a failed import surfaces a clear error.
   * @param {ArrayBuffer} buf
   */
  async importDocxBuffer(buf) {
    try {
      this._source = await this._importDocx(buf);
      this._error = null;
    } catch (e) {
      this._error = String(e.message || e);
    }
    this.requestUpdate();
    return this._source;
  }

  /**
   * Export the current document. format "docx": when a runtime is docked, route
   * through the Host (pandoc.wasm, max fidelity); otherwise the floor `exportDocx`
   * builds the .docx Blob in-browser. Emits `work-doc-export {format, ok}`. Returns
   * the Blob (or null on failure).
   * @param {"docx"} [format]
   * @returns {Promise<Blob|null>}
   */
  async export(format = "docx") {
    if (format !== "docx") {
      this.dispatchEvent(new CustomEvent("work-doc-export", { bubbles: true, composed: true, detail: { format, ok: false, error: `unsupported format ${format}` } }));
      return null;
    }
    try {
      let blob;
      // Host tier (pandoc over the Dock) when docked — kept optional; the floor is
      // the always-available default and the only path required to wire here.
      if (this.host && this.host.available("runtime") && this.host.runtimeUrl) {
        blob = await this._exportViaHost(this.source);
      }
      if (!blob) {
        const { exportDocx } = await import("./docx-io.js");
        blob = await exportDocx(this.source);
      }
      this.dispatchEvent(new CustomEvent("work-doc-export", { bubbles: true, composed: true, detail: { format, ok: true } }));
      return blob;
    } catch (e) {
      this.dispatchEvent(new CustomEvent("work-doc-export", { bubbles: true, composed: true, detail: { format, ok: false, error: String(e.message || e) } }));
      return null;
    }
  }

  async _exportViaHost(source) {
    try {
      const r = await this.host.request("/api/doc/export", { body: { format: "docx", source } });
      if (r && r.blobBase64) {
        const bin = atob(r.blobBase64);
        const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
        return new Blob([bytes], { type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document" });
      }
    } catch { /* fall through to the floor */ }
    return null;
  }

  /** The document source string (the artifact's truth). */
  get source() { return this._source || ""; }
  set source(v) { this._source = v; this._error = null; this.requestUpdate(); }

  /** The heading outline — consumed by <work-doc-outline>. */
  get outline() { return parseOutline(this.source); }

  render() {
    if (this._error) return html`<div class="error">Could not load document: ${this._error}</div>`;
    if (this._source == null) return html`<div class="loading">Loading…</div>`;

    // Pull live-cell blocks out into placeholders, render prose, then re-insert
    // real <work-doc-cell> elements after the DOM is updated (so their own shadow
    // DOM mounts and computes).
    this._pendingCells = [];
    const body = renderDoc(this._source, {
      onCell: ({ lang, code }) => {
        const id = `workcell-${++_cellSeq}`;
        this._pendingCells.push({ id, lang, code });
        return `<div data-cell="${id}"></div>`;
      },
    });
    // body is trusted output of OUR renderer (escaped at the source — see render.js).
    return html`<article class="doc prose">${unsafeHTML(body)}</article>`;
  }

  updated() {
    // mount the deferred live cells
    for (const c of this._pendingCells || []) {
      const slot = this.shadowRoot.querySelector(`[data-cell="${c.id}"]`);
      if (!slot) continue;
      const cell = document.createElement("work-doc-cell");
      cell.setAttribute("lang", c.lang);
      cell.textContent = c.code;
      slot.replaceWith(cell);
    }
    this._pendingCells = [];
    // announce the outline for siblings (e.g. <work-doc-outline>)
    this.dispatchEvent(new CustomEvent("work-doc:rendered", {
      bubbles: true, composed: true, detail: { outline: this.outline, id: this.id },
    }));
  }
}

define("work-doc", WbDoc);
