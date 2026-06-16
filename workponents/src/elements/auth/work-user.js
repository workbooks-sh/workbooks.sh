// <work-user> — avatar + identity menu, bound to the current session.
//
// Reads the identity seam (over this.host): shows the signed-in user's avatar
// (image or initials), and on click reveals a menu with name/email + sign-out.
// Subscribes to the seam, so it updates live when the session changes elsewhere
// (e.g. <work-auth> resolves a sign-in). Sign-out drives the seam and emits
// `work-auth-changed` {user:null}. When anonymous it renders nothing (a <work-gate>
// or <work-auth> handles the anon case).
//
// Variants:  variant = "menu" | "compact"  (compact = avatar only, no name)
// Events:  work-auth-changed { user, providers }  (on sign-out)
// Usage:  <work-user></work-user>   ·   <work-user variant="compact"></work-user>
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getIdentity } from "./identity.js";

const VARIANTS = defineVariants({
  variant: { options: ["menu", "compact"], default: "menu" },
});

export class WorkUser extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "open"];

  static styles = css`
    :host { display: inline-block; font-family: var(--wb-font); color: var(--wb-fg); position: relative; }
    :host([hidden]) { display: none; }
    .trigger {
      display: inline-flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-1) var(--wb-space-2) var(--wb-space-1) var(--wb-space-1);
      border: 1.5px solid var(--wb-border); border-radius: var(--wb-radius-pill);
      background: var(--wb-surface); color: var(--wb-fg); cursor: pointer;
      transition: background var(--wb-dur) var(--wb-ease), border-color var(--wb-dur) var(--wb-ease),
                  box-shadow var(--wb-dur) var(--wb-ease);
    }
    .trigger:hover { background: var(--wb-surface-soft); border-color: var(--wb-border-strong); }
    .trigger:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    :host([variant="compact"]) .trigger { padding: 0; border-radius: 50%; border-color: transparent; }
    :host([variant="compact"]) .name { display: none; }

    .avatar {
      width: 28px; height: 28px; flex: none; border-radius: 50%;
      display: inline-grid; place-items: center; overflow: hidden;
      background: var(--wb-brand); color: var(--wb-on-brand);
      font: 700 11px var(--wb-font-mono); letter-spacing: .02em;
    }
    .avatar img { width: 100%; height: 100%; object-fit: cover; }
    .name { font-size: var(--wb-text-sm); font-weight: 600; max-width: 14ch;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .caret { width: 12px; height: 12px; color: var(--wb-fg-subtle); flex: none; }
    :host([variant="compact"]) .caret { display: none; }

    .menu {
      position: absolute; top: calc(100% + 6px); right: 0; min-width: 220px; z-index: 30;
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); box-shadow: var(--wb-shadow); padding: var(--wb-space-2);
      display: none;
    }
    :host([open]) .menu { display: block; }
    .who { display: flex; align-items: center; gap: var(--wb-space-3);
      padding: var(--wb-space-2) var(--wb-space-2) var(--wb-space-3); }
    .who .avatar { width: 36px; height: 36px; font-size: 13px; }
    .who .meta { min-width: 0; }
    .who .meta .n { font-weight: 600; font-size: var(--wb-text); }
    .who .meta .e { color: var(--wb-fg-muted); font-size: var(--wb-text-sm);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sep { height: 1px; background: var(--wb-border); margin: var(--wb-space-1) 0; }
    .item {
      display: flex; align-items: center; gap: var(--wb-space-2); width: 100%;
      padding: var(--wb-space-2) var(--wb-space-2); border: 0; border-radius: var(--wb-radius-sm);
      background: none; color: var(--wb-fg); font: var(--wb-text) var(--wb-font); text-align: left;
      cursor: pointer;
    }
    .item:hover { background: var(--wb-surface-soft); }
    .item.danger { color: var(--wb-err); }
    .item svg { width: 15px; height: 15px; flex: none; }
  `;

  get identity() {
    return this._identity || (this._identity = getIdentity());
  }
  set identity(cap) {
    this._unsub?.();
    this._identity = cap;
    this._listen();
    if (this._connected) this.requestUpdate();
  }

  _listen() {
    this._unsub = this.identity.subscribe(() => this.requestUpdate());
  }

  _initials(name, email) {
    const src = name || email || "?";
    const parts = src.replace(/@.*/, "").split(/[\s._-]+/).filter(Boolean);
    return ((parts[0]?.[0] || "") + (parts[1]?.[0] || "")).toUpperCase() || src[0].toUpperCase();
  }

  async connectedCallback() {
    super.connectedCallback();
    if (!this._wired) {
      this._wired = true;
      this._listen();
      // close on outside click
      this._onDoc = (e) => { if (!this.contains(e.target)) this.removeAttribute("open"); };
      document.addEventListener("click", this._onDoc);
    }
    // resolve a possibly-async real session
    await this.identity.session();
    this.requestUpdate();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._unsub?.();
    document.removeEventListener("click", this._onDoc);
  }

  async _signOut() {
    this.removeAttribute("open");
    const snap = await this.identity.signOut();
    this.dispatchEvent(new CustomEvent("work-auth-changed", { bubbles: true, composed: true, detail: snap }));
  }

  _avatar(user) {
    return user.avatar
      ? html`<span class="avatar"><img src=${user.avatar} alt="" /></span>`
      : html`<span class="avatar">${this._initials(user.name, user.email)}</span>`;
  }

  render() {
    const { user } = this.identity.peek();
    if (!user) { this.setAttribute("hidden", ""); return ""; }
    this.removeAttribute("hidden");
    return html`
      <button class="trigger" part="trigger" aria-haspopup="menu" aria-label="Account"
        @click=${() => this.toggleAttribute("open")}>
        ${this._avatar(user)}
        <span class="name">${user.name || user.email || "Account"}</span>
        <svg class="caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>
      </button>
      <div class="menu" part="menu" role="menu">
        <div class="who">
          ${this._avatar(user)}
          <div class="meta">
            <div class="n">${user.name || "—"}</div>
            <div class="e">${user.email || ""}</div>
          </div>
        </div>
        <div class="sep"></div>
        <button class="item signout danger" role="menuitem" part="signout" @click=${() => this._signOut()}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/></svg>
          Sign out
        </button>
      </div>`;
  }
}

define("work-user", WorkUser);
