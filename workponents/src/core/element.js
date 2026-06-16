// WbElement — the base for every <wb-*> element, re-based onto Lit.
//
// Lit is the FLOOR's engine now (the approved adoption pass): surgical template
// updates instead of an innerHTML nuke, while every workponents convention is
// preserved so the rest of the library migrates mechanically. Lit is loaded as a
// bare specifier ("lit") — buildless via an import map in the demos, a peer dep
// for SDK consumers (see README / demo/lit-foundation.html). No bundler, no
// `bun install`.
//
// Conventions (unchanged — the whole library follows these):
//   • Shadow DOM (open) for style isolation; --work-* tokens inherit through it.
//   • `static styles` = the component CSS as a Lit `css``` CSSResult (was a
//     string). Use ONLY var(--work-*). Variants targeted via :host([name="value"]).
//   • `render()` returns a Lit `html``` TemplateResult (was a string) — surgical
//     updates, no innerHTML rewrite.
//   • `static props` = reflected attributes that re-render on change (variants,
//     state). They are mapped to Lit reactive properties automatically.
//   • `static variants` defaults are reflected on connect (before first paint) so
//     :host([name="value"]) selectors always match.
//   • Capability is reached through `this.host` (the Dock seam), never hardcoded.
//   • Register with `define()` (idempotent — safe to load twice).
//
// `attr()` / `boolAttr()` helpers are preserved for elements that read attributes
// directly in render(). Re-exports `html` + `css` so domain files import the whole
// authoring surface from one place:
//   import { WbElement, html, css, define } from "../core/element.js";

import { LitElement, html, css } from "lit";
import { getHost } from "./host.js";

export { html, css };

export class WbElement extends LitElement {
  /** @type {import("lit").CSSResult} component CSS — override with css``; use only var(--work-*) */
  static styles = css``;

  /** @type {string[]} reflected attributes that trigger a re-render */
  static props = [];

  // Register each subclass's `static props` as Lit reactive properties so an
  // attribute change fires attributeChangedCallback + re-renders (the old
  // observedAttributes contract). NOTE: a base-class `static get properties()` is
  // NOT honored — Lit's finalize() only reads each class's OWN `properties`. So we
  // hook finalize() and createProperty() per subclass instead. Reflect ONLY the
  // short variant enums (so el.variant = "soft" still matches :host([variant]));
  // never reflect data attributes like `rows`/`csv`/`query` (can be huge strings).
  static finalize() {
    super.finalize();
    const variants = this.variants || {};
    for (const name of this.props || []) {
      const key = this._propKey(name);
      // Skip names that already exist on the prototype as a method/getter (e.g. a
      // `variant(name)` helper, an `open()` method). Creating a reactive accessor
      // there THROWS in Lit dev mode ("declared as a reactive property but it's
      // actually declared as a value on the prototype"). The attribute is still
      // OBSERVED via observedAttributes below, so attribute changes still fire
      // attributeChangedCallback → the element's reload/requestUpdate runs.
      if (key in this.prototype) continue;
      this.createProperty(key, {
        type: String,
        attribute: name,
        reflect: Object.prototype.hasOwnProperty.call(variants, name),
      });
    }
  }

  // Guarantee every `static props` attribute is OBSERVED (the browser reads this
  // at customElements.define() time). This is the bulletproof half: even if Lit's
  // reactive-property finalize timing misses one, attribute changes still fire
  // attributeChangedCallback → the element's reload/requestUpdate handler runs.
  static get observedAttributes() {
    const base = super.observedAttributes || [];
    return Array.from(new Set([...base, ...(this.props || [])]));
  }

  // Attribute names may contain dashes; reactive-property keys must be identifiers.
  static _propKey(name) {
    return name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
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

  /** Override: return the template (Lit `html```). */
  render() {
    return html`<slot></slot>`;
  }

  connectedCallback() {
    // Reflect default variants BEFORE Lit's first render so :host([name="value"])
    // selectors match the very first paint, even when the author sets only some
    // (e.g. tone without variant).
    const v = this.constructor.variants;
    if (v) {
      for (const [name, def] of Object.entries(v)) {
        if (!this.hasAttribute(name)) this.setAttribute(name, def.default);
      }
    }
    super.connectedCallback();
  }
}

/** Idempotent custom-element registration (safe across double-loads). */
export function define(name, ctor) {
  if (!customElements.get(name)) customElements.define(name, ctor);
  return ctor;
}
