// <auth-gate> — the declarative auth guard. Conditionally renders its slotted
// content by auth state, reading the identity seam (over this.host).
//
//   <auth-gate when="authed">      …shown only when signed in…
//     <p slot="fallback">Please sign in.</p>   <!-- shown when the test fails -->
//   </auth-gate>
//
// `when` values:
//   authed      — a user session exists
//   anon        — no session
//   role:<name> — a session whose user.roles includes <name>
//
// It subscribes to the seam, so it flips live the moment the session changes
// (e.g. <auth-panel> resolves, or <auth-user> signs out) — no host wiring needed.
// Light-DOM content is projected; the default slot is the protected content,
// slot="fallback" is shown otherwise. Emits `work-gate-change` {passed, when}.
import { WbElement, html, css, define } from "../../core/element.js";
import { getIdentity } from "./identity.js";

export class WorkGate extends WbElement {
  static props = ["when"];

  static styles = css`
    :host { display: contents; }
    /* Toggle which slot is visible by the resolved gate state. */
    .pass, .fall { display: contents; }
    :host(:not([data-pass])) .pass { display: none; }
    :host([data-pass]) .fall { display: none; }
  `;

  get identity() {
    return this._identity || (this._identity = getIdentity());
  }
  set identity(cap) {
    this._unsub?.();
    this._identity = cap;
    this._listen();
    this._evaluate();
  }

  _listen() {
    this._unsub = this.identity.subscribe(() => this._evaluate());
  }

  _test() {
    const when = this.attr("when", "authed");
    const { user } = this.identity.peek();
    if (when === "anon") return !user;
    if (when.startsWith("role:")) {
      const role = when.slice(5).trim();
      return !!user && Array.isArray(user.roles) && user.roles.includes(role);
    }
    return !!user; // "authed"
  }

  _evaluate() {
    const passed = this._test();
    const had = this.hasAttribute("data-pass");
    if (passed) this.setAttribute("data-pass", "");
    else this.removeAttribute("data-pass");
    if (passed !== had) {
      this.dispatchEvent(new CustomEvent("work-gate-change", {
        bubbles: true, composed: true, detail: { passed, when: this.attr("when", "authed") },
      }));
    }
  }

  async connectedCallback() {
    super.connectedCallback();
    if (!this._wired) {
      this._wired = true;
      this._listen();
    }
    await this.identity.session();
    this._evaluate();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._unsub?.();
  }

  attributeChangedCallback(name, old, val) {
    super.attributeChangedCallback?.(name, old, val);
    // `when` changes (or data-pass) shouldn't blow away the slots; just re-test.
    if (name === "when" && this._connected) this._evaluate();
  }

  render() {
    // Two slot lanes; CSS shows exactly one per the resolved data-pass state.
    return html`
      <span class="pass"><slot></slot></span>
      <span class="fall"><slot name="fallback"></slot></span>`;
  }
}

define("auth-gate", WorkGate);
