// <work-ref> — THE edge primitive (spine). One element for every edge in the graph:
// a link, a dependency, a data binding — AND a type. Meaning comes from where it sits
// and from `rel`:
//
//   <work-ref to="setup/auth"/>            a pointer — follows to a target (link/next-step)
//   <work-ref to="x" as="template"/>       a typed pointer (template | skill | cmd | doc)
//   <work-ref rel="kit"/>                  a TYPE edge — asserts its container IS a work-kit
//                                          (rel=kit|skill|agent); this is "tagging = C"
//   <work-ref rel="call" to="deploy"/>     a CALL edge — invokes a host capability through
//                                          the Dock (RPC surface; the transport is RCP)
//   <work-ref from="customers"/>           a data-binding edge (invisible; the binding IS the edge)
//
// A pointer renders inline and emits `work-ref-follow { to, as }`. A call edge invokes
// `this.host` and emits `work-ref-call { to, ok, result }`. A type edge renders a small
// provenance badge. A pure binding renders nothing — it's structure, not UI.
import { WbElement, html, css, define } from "../../core/element.js";

export class WorkRef extends WbElement {
  static props = ["to", "rel", "from", "as"];

  static styles = css`
    :host { display: contents; font-family: var(--work-font); }
    a { display: inline-flex; align-items: baseline; gap: 4px; cursor: pointer;
      color: var(--work-brand-ink); text-decoration: none;
      border-bottom: 1px solid var(--work-brand-soft); }
    a:hover { border-bottom-color: var(--work-brand); }
    a .arrow { font-size: .85em; color: var(--work-fg-subtle); }
    a .kind { font: 600 var(--work-text-sm) var(--work-font-mono); color: var(--work-fg-subtle); }
    .badge { display: inline-block; font: 600 var(--work-text-sm) var(--work-font-mono);
      text-transform: uppercase; letter-spacing: .06em; color: var(--work-fg-subtle);
      border: 1px solid var(--work-border); border-radius: var(--work-radius-pill); padding: 0 8px; }
  `;

  _follow(e) {
    e.preventDefault();
    this.dispatchEvent(new CustomEvent("work-ref-follow", {
      bubbles: true, composed: true,
      detail: { to: this.attr("to"), as: this.attr("as") || null },
    }));
  }

  // call edge: invoke a host capability through the Dock (RPC over RCP).
  async _call(e) {
    e.preventDefault();
    const to = this.attr("to");
    let ok = false, result = null;
    try {
      let args = {};
      try { args = JSON.parse(this.attr("args") || "{}"); } catch {}
      const r = await this.host.request(`/call/${to}`, { body: args });
      ok = !!(r && r.ok !== false); result = r;
    } catch (err) {
      result = "needs runtime: " + (err.message || err);
    }
    this.dispatchEvent(new CustomEvent("work-ref-call", {
      bubbles: true, composed: true, detail: { to, ok, result },
    }));
  }

  render() {
    const to = this.attr("to"), rel = this.attr("rel"), as = this.attr("as");
    // call edge: a followable capability invocation through the Dock.
    if (rel === "call" && to) {
      const label = (this.textContent || "").trim() || to;
      return html`<a href="#" @click=${(e) => this._call(e)}
        >${label}<span class="arrow">⚡</span><span class="kind">call</span></a>`;
    }
    // type edge: assert the container's type — render as provenance.
    if (rel && !to) return html`<span class="badge" title="type edge">${rel}</span>`;
    // pure binding edge: invisible structure.
    if (this.attr("from") && !to) return html``;
    // pointer: an inline, followable link. Label = slotted text or the target id.
    if (to) {
      const label = (this.textContent || "").trim() || to;
      return html`<a href="#${to}" @click=${(e) => this._follow(e)}
        >${label}<span class="arrow">↗</span>${as ? html`<span class="kind">${as}</span>` : ""}</a>`;
    }
    return html`<slot></slot>`;
  }
}

define("work-ref", WorkRef);
