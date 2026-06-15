// <wb-doc> — renders an org/markdown document directly from its source. The
// reinvention: the document IS its source (preview ≡ source) — there is no
// separate document model, so the same bytes an agent or cursor edits are what
// renders. Source comes from a `src` attr (a URL or inline) or the element's
// own inner text.
//
// Standalone fidelity: a dependency-free markdown + basic-org renderer
// (./render.js) — headings, lists, code, emphasis, links, tables, blockquotes,
// rules, checkboxes, and org TODO pills + tags. For FULL org fidelity (property
// drawers, footnotes, citations, #+EXEC component blocks, exact orgize parity)
// a wired Host routes rendering through the OQL kernel (oql.wasm) — the same
// pipeline desktop/src/lib/org-renderer uses; this element reaches it via
// `this.host` when the `kernel` capability is available, and falls back to the
// standalone renderer otherwise.
//
// Live cells: fenced ```sql / ```polars / ```py / ```js / ```chart blocks (and
// the org #+begin_src equivalents) become <wb-doc-cell> elements — first-class
// computed blocks, the docs-domain differentiator.
//
// Cross-element: emits `wb-doc:rendered` with the parsed outline, so a sibling
// <wb-doc-outline for="…"> stays auto-synced.
import { WbElement, define } from "../../core/element.js";
import { renderDoc, parseOutline } from "./render.js";
import { PROSE_CSS } from "./prose.js";
import "./wb-doc-cell.js";

let _cellSeq = 0;

export class WbDoc extends WbElement {
  static props = ["src", "format"];

  static styles = `
    :host { display: block; }
    .doc { max-width: 76ch; margin: 0 auto; }
    .loading, .error { color: var(--wb-fg-muted); font-family: var(--wb-font); padding: var(--wb-space-4); }
    .error { color: var(--wb-err); }
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
      this._source = await res.text();
      this.update();
    } catch (e) {
      this._error = String(e.message || e);
      this.update();
    }
  }

  /** The document source string (the artifact's truth). */
  get source() { return this._source || ""; }
  set source(v) { this._source = v; this._error = null; this.update(); }

  /** The heading outline — consumed by <wb-doc-outline>. */
  get outline() { return parseOutline(this.source); }

  render() {
    if (this._error) return `<div class="error">Could not load document: ${this._error}</div>`;
    if (this._source == null) return `<div class="loading">Loading…</div>`;

    // Pull live-cell blocks out into placeholders, render prose, then re-insert
    // real <wb-doc-cell> elements after innerHTML is set (so their own shadow
    // DOM mounts and computes).
    this._pendingCells = [];
    const body = renderDoc(this._source, {
      onCell: ({ lang, code }) => {
        const id = `wbcell-${++_cellSeq}`;
        this._pendingCells.push({ id, lang, code });
        return `<div data-cell="${id}"></div>`;
      },
    });
    return `<article class="doc prose">${body}</article>`;
  }

  update() {
    super.update();
    // mount the deferred live cells
    for (const c of this._pendingCells || []) {
      const slot = this.shadowRoot.querySelector(`[data-cell="${c.id}"]`);
      if (!slot) continue;
      const cell = document.createElement("wb-doc-cell");
      cell.setAttribute("lang", c.lang);
      cell.textContent = c.code;
      slot.replaceWith(cell);
    }
    this._pendingCells = [];
    // announce the outline for siblings (e.g. <wb-doc-outline>)
    this.dispatchEvent(new CustomEvent("wb-doc:rendered", {
      bubbles: true, composed: true, detail: { outline: this.outline, id: this.id },
    }));
  }
}

define("wb-doc", WbDoc);
