// WbElement — the thin base for every <wb-*> element. Zero dependencies.
//
// Conventions (the whole library follows these):
//   • Shadow DOM (open) for style isolation; --wb-* tokens inherit through it.
//   • `static styles` = the component CSS string, using ONLY var(--wb-*).
//   • `render()` returns the template HTML string.
//   • `static props` = reflected attributes that re-render on change (variants,
//     state). Variant attributes are targeted in CSS via :host([name="value"]).
//   • Capability is reached through `this.host` (the Dock seam), never hardcoded.
//
// Styles are adopted once via a shared constructable stylesheet (cheap re-render:
// only the template's innerHTML is rewritten). Define elements with `define()`
// (idempotent — safe to load twice, like the wavelet runtime).

import { getHost } from "./host.js";

export class WbElement extends HTMLElement {
  /** @type {string} component CSS — override; use only var(--wb-*) */
  static styles = "";
  /** @type {string[]} reflected attributes that trigger a re-render */
  static props = [];

  static get observedAttributes() {
    return this.props;
  }

  constructor() {
    super();
    this.attachShadow({ mode: "open" });
    this._sheet = new CSSStyleSheet();
    this.shadowRoot.adoptedStyleSheets = [this._sheet];
    this._stylesApplied = false;
    this._connected = false;
  }

  /** The Dock/Host capability seam — local | runtime (RCP) | kernel. */
  get host() {
    return getHost();
  }

  /** Read an attribute with a default. */
  attr(name, fallback = null) {
    return this.hasAttribute(name) ? this.getAttribute(name) : fallback;
  }

  /** Read a boolean attribute (present = true). */
  boolAttr(name) {
    return this.hasAttribute(name);
  }

  /** Override: return the template HTML string. */
  render() {
    return "<slot></slot>";
  }

  connectedCallback() {
    this._connected = true;
    if (!this._stylesApplied) {
      this._sheet.replaceSync(this.constructor.styles || "");
      this._stylesApplied = true;
    }
    // Reflect default variants so :host([name="value"]) selectors always match,
    // even when the author sets only some of them (e.g. tone without variant).
    const v = this.constructor.variants;
    if (v) for (const [name, def] of Object.entries(v)) {
      if (!this.hasAttribute(name)) this.setAttribute(name, def.default);
    }
    this.update();
  }

  attributeChangedCallback() {
    if (this._connected) this.update();
  }

  /** Re-render the template into the shadow root. */
  update() {
    this.shadowRoot.innerHTML = this.render();
  }
}

/** Idempotent custom-element registration (safe across double-loads). */
export function define(name, ctor) {
  if (!customElements.get(name)) customElements.define(name, ctor);
  return ctor;
}
