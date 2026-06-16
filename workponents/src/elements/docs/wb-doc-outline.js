// <work-doc-outline> — a clickable heading tree for a document, auto-synced.
//
// Binds to a <work-doc> by id (`for="my-doc"`) or, with no `for`, to the nearest
// preceding/containing <work-doc>. It reads that doc's `.outline` and re-syncs on
// the doc's `work-doc:rendered` event — so editing the source (composition-as-
// source) keeps the outline live with no manual wiring. Clicking a heading
// scrolls it into view inside the doc's shadow root.
import { WbElement, html, css, define } from "../../core/element.js";

export class WbDocOutline extends WbElement {
  static props = ["for"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); }
    nav { border-left: 2px solid var(--work-border); padding-left: var(--work-space-3); }
    .label { font-family: var(--work-font-mono); font-size: 0.62rem; font-weight: 700;
      letter-spacing: 0.18em; text-transform: uppercase; color: var(--work-fg-subtle);
      margin: 0 0 var(--work-space-2); }
    ol { list-style: none; margin: 0; padding: 0; }
    li { margin: 1px 0; }
    a { display: block; text-decoration: none; color: var(--work-fg-muted);
      font-size: var(--work-text-sm); line-height: 1.5; padding: 3px var(--work-space-2);
      border-radius: var(--work-radius-sm); cursor: pointer;
      transition: color var(--work-dur) var(--work-ease), background var(--work-dur) var(--work-ease); }
    a:hover { color: var(--work-fg); background: var(--work-surface-soft); }
    a.active { color: var(--work-brand); background: var(--work-brand-soft); font-weight: 600; }
    .l2 { padding-left: var(--work-space-3); }
    .l3 { padding-left: var(--work-space-5); font-size: 0.95em; }
    .l4, .l5, .l6 { padding-left: calc(var(--work-space-5) + var(--work-space-3)); font-size: 0.9em; }
    .empty { color: var(--work-fg-subtle); font-size: var(--work-text-sm); }
  `;

  connectedCallback() {
    super.connectedCallback();
    this._bind();
  }

  disconnectedCallback() {
    if (this._doc && this._onRender) this._doc.removeEventListener("work-doc:rendered", this._onRender);
    super.disconnectedCallback();
  }

  _findDoc() {
    const ref = this.attr("for");
    if (ref) {
      const root = this.getRootNode();
      return (root.getElementById && root.getElementById(ref)) || document.getElementById(ref);
    }
    // nearest work-doc: a previous sibling, or anywhere in the document
    let n = this.previousElementSibling;
    while (n) { if (n.tagName === "WORK-DOC") return n; n = n.previousElementSibling; }
    return document.querySelector("work-doc");
  }

  _bind() {
    const doc = this._findDoc();
    if (!doc) { this._outline = []; this.requestUpdate(); return; }
    this._doc = doc;
    this._onRender = (e) => { this._outline = (e.detail && e.detail.outline) || doc.outline; this.requestUpdate(); };
    doc.addEventListener("work-doc:rendered", this._onRender);
    // doc may have already rendered before we bound — read it now if so
    if (doc.outline && doc.outline.length) { this._outline = doc.outline; this.requestUpdate(); }
    else if (doc._source == null) { /* will fire on load */ }
    else { this._outline = doc.outline || []; this.requestUpdate(); }
  }

  _scrollTo(id) {
    if (!this._doc) return;
    const root = this._doc.shadowRoot || this._doc;
    const target = root.getElementById ? root.getElementById(id) : root.querySelector(`#${CSS.escape(id)}`);
    if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
    this.shadowRoot.querySelectorAll("a").forEach((a) => a.classList.toggle("active", a.dataset.id === id));
  }

  render() {
    const items = this._outline || [];
    if (!items.length) return html`<nav><p class="label">Outline</p><p class="empty">No headings yet.</p></nav>`;
    return html`<nav>
      <p class="label">Outline</p>
      <ol>${items.map((h) => html`<li><a class="l${h.level}" data-id=${h.id} href="#${h.id}"
        @click=${(e) => { e.preventDefault(); this._scrollTo(h.id); }}>${h.text}</a></li>`)}</ol>
    </nav>`;
  }
}

define("work-doc-outline", WbDocOutline);
