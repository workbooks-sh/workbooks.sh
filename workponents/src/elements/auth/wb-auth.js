// <wb-auth> — the sign-in surface. Provider buttons (themed like wb-button) +
// an email form (password or magic-link), with loading/error states.
//
// It does NOT hardcode a provider. It reads the provider list + drives sign-in
// through the identity seam (over this.host), which is provider-agnostic —
// Clerk/Auth0/WorkOS/BetterAuth are server-side wirings behind it. On every
// user action it emits `wb-auth-intent` {method, provider, email?}; when the
// seam resolves a session it emits `wb-auth-changed` {user, providers}.
//
// Attributes:
//   mode      = "password" | "magic"   (email form style; default password)
//   providers = "google,github,workos" (override the seam's provider ids)
//   heading   = surface title          (default "Sign in")
// Events (bubbles, composed):
//   wb-auth-intent  { method:"oauth"|"password"|"magic", provider?, email? }
//   wb-auth-changed { user, providers }   (on a resolved session)
//   wb-auth-error   { message }
//
// Usage:  <wb-auth heading="Welcome back"></wb-auth>
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getIdentity } from "./identity.js";

const VARIANTS = defineVariants({
  mode: { options: ["password", "magic"], default: "password" },
  state: { options: ["idle", "loading", "error"], default: "idle" },
});

// Provider brand glyphs (inline, token-colored via currentColor where possible).
const GLYPHS = {
  google: `<svg viewBox="0 0 24 24" width="16" height="16"><path fill="#4285F4" d="M21.6 12.2c0-.6-.06-1.2-.16-1.8H12v3.4h5.4a4.6 4.6 0 0 1-2 3v2.5h3.2c1.9-1.7 3-4.3 3-7.1z"/><path fill="#34A853" d="M12 22c2.7 0 5-.9 6.6-2.4l-3.2-2.5c-.9.6-2 1-3.4 1-2.6 0-4.8-1.7-5.6-4.1H3.1v2.6A10 10 0 0 0 12 22z"/><path fill="#FBBC05" d="M6.4 14c-.2-.6-.3-1.3-.3-2s.1-1.4.3-2V7.4H3.1A10 10 0 0 0 2 12c0 1.6.4 3.1 1.1 4.6L6.4 14z"/><path fill="#EA4335" d="M12 5.9c1.5 0 2.8.5 3.8 1.5l2.8-2.8A10 10 0 0 0 12 2 10 10 0 0 0 3.1 7.4L6.4 10c.8-2.4 3-4.1 5.6-4.1z"/></svg>`,
  github: `<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M12 2A10 10 0 0 0 8.8 21.5c.5.1.7-.2.7-.5v-1.7c-2.8.6-3.4-1.3-3.4-1.3-.5-1.2-1.1-1.5-1.1-1.5-.9-.6.1-.6.1-.6 1 .1 1.5 1 1.5 1 .9 1.5 2.3 1.1 2.9.8.1-.6.3-1.1.6-1.4-2.2-.3-4.6-1.1-4.6-5a3.9 3.9 0 0 1 1-2.7 3.6 3.6 0 0 1 .1-2.7s.8-.3 2.7 1a9.4 9.4 0 0 1 5 0c1.9-1.3 2.7-1 2.7-1 .5 1.4.2 2.4.1 2.7.6.7 1 1.6 1 2.7 0 3.9-2.3 4.7-4.6 5 .4.3.7.9.7 1.9v2.8c0 .3.2.6.7.5A10 10 0 0 0 12 2z"/></svg>`,
  workos: `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="11" width="18" height="10" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>`,
};
const fallbackGlyph = `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>`;

export class WbAuth extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "providers", "heading"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .card {
      max-width: 360px; box-sizing: border-box;
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius-lg);
      background: var(--wb-surface); padding: var(--wb-space-5);
      box-shadow: var(--wb-shadow);
    }
    h3 { margin: 0 0 var(--wb-space-1); font-family: var(--wb-font-display);
      font-size: var(--wb-text-lg); font-weight: 600; letter-spacing: -.01em; }
    .sub { margin: 0 0 var(--wb-space-4); color: var(--wb-fg-muted); font-size: var(--wb-text-sm); }

    .providers { display: flex; flex-direction: column; gap: var(--wb-space-2); }
    .provider {
      font-family: var(--wb-font); font-weight: 600; font-size: var(--wb-text);
      display: inline-flex; align-items: center; justify-content: center; gap: var(--wb-space-2);
      width: 100%; box-sizing: border-box;
      padding: var(--wb-space-3) var(--wb-space-4);
      border-radius: var(--wb-radius); border: 1.5px solid var(--wb-border-strong);
      background: var(--wb-surface); color: var(--wb-fg); cursor: pointer;
      transition: transform var(--wb-dur) var(--wb-ease), background var(--wb-dur) var(--wb-ease),
                  border-color var(--wb-dur) var(--wb-ease), box-shadow var(--wb-dur) var(--wb-ease);
    }
    .provider:hover { transform: translateY(-1px); background: var(--wb-surface-soft); }
    .provider:active { transform: translateY(0); }
    .provider:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    .provider svg { flex: none; }

    .div { display: flex; align-items: center; gap: var(--wb-space-3);
      margin: var(--wb-space-4) 0; color: var(--wb-fg-subtle);
      font: 600 10px var(--wb-font-mono); letter-spacing: .14em; text-transform: uppercase; }
    .div::before, .div::after { content: ""; flex: 1; height: 1px; background: var(--wb-border); }

    form { display: flex; flex-direction: column; gap: var(--wb-space-3); }
    label { font: 600 11px var(--wb-font-mono); letter-spacing: .06em;
      text-transform: uppercase; color: var(--wb-fg-muted); }
    .field { display: flex; flex-direction: column; gap: var(--wb-space-1); }
    input {
      font: var(--wb-text)/1.4 var(--wb-font); color: var(--wb-fg);
      padding: var(--wb-space-3); border-radius: var(--wb-radius);
      border: 1.5px solid var(--wb-border-strong); background: var(--wb-bg);
      transition: border-color var(--wb-dur) var(--wb-ease), box-shadow var(--wb-dur) var(--wb-ease);
    }
    input::placeholder { color: var(--wb-fg-subtle); }
    input:focus-visible { outline: none; border-color: var(--wb-brand); box-shadow: 0 0 0 3px var(--wb-ring); }

    .submit {
      font-family: var(--wb-font); font-weight: 600; font-size: var(--wb-text);
      display: inline-flex; align-items: center; justify-content: center; gap: var(--wb-space-2);
      width: 100%; box-sizing: border-box; margin-top: var(--wb-space-1);
      padding: var(--wb-space-3) var(--wb-space-4);
      border: 1.5px solid transparent; border-radius: var(--wb-radius);
      background: var(--wb-brand); color: var(--wb-on-brand); cursor: pointer;
      transition: filter var(--wb-dur) var(--wb-ease), opacity var(--wb-dur) var(--wb-ease);
    }
    .submit:hover { filter: brightness(1.06); }
    .submit:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }

    .err { display: none; color: var(--wb-err); font-size: var(--wb-text-sm); }
    :host([state="error"]) .err { display: block; }

    .alt { margin-top: var(--wb-space-3); text-align: center; font-size: var(--wb-text-sm);
      color: var(--wb-fg-muted); }
    .alt button { background: none; border: 0; color: var(--wb-brand); cursor: pointer;
      font: inherit; font-weight: 600; padding: 0; }

    /* loading: lock the surface, spinner on the active control */
    :host([state="loading"]) .card { pointer-events: none; }
    :host([state="loading"]) input { opacity: .6; }
    .spin { width: 14px; height: 14px; border-radius: 50%; flex: none;
      border: 2px solid currentColor; border-right-color: transparent;
      animation: wb-spin .7s linear infinite; }
    @keyframes wb-spin { to { transform: rotate(360deg); } }
  `;

  get identity() {
    return this._identity || (this._identity = getIdentity());
  }
  set identity(cap) {
    this._identity = cap;
    if (this._connected) this.update();
  }

  _providers() {
    const override = this.attr("providers");
    if (override) {
      const known = this.identity.providers;
      return override.split(",").map((id) => {
        id = id.trim();
        return known.find((p) => p.id === id) || { id, name: id };
      });
    }
    return this.identity.providers;
  }

  _emitIntent(detail) {
    this.dispatchEvent(new CustomEvent("wb-auth-intent", { bubbles: true, composed: true, detail }));
  }

  async _run(intent) {
    this._emitIntent(intent);
    this.setAttribute("state", "loading");
    try {
      const snap = intent.method === "magic"
        ? await this.identity.requestMagicLink({ email: intent.email })
        : await this.identity.signIn(intent);
      this.setAttribute("state", "idle");
      // A resolved user session → announce it. (Magic-link on a real host may be
      // pending; the seam's mock resolves it directly.)
      if (snap?.user) {
        this.dispatchEvent(new CustomEvent("wb-auth-changed", { bubbles: true, composed: true, detail: snap }));
      }
    } catch (err) {
      this._error(err?.message || "Sign-in failed");
    }
  }

  _error(message) {
    this._errMsg = message;
    this.setAttribute("state", "error");
    this.dispatchEvent(new CustomEvent("wb-auth-error", { bubbles: true, composed: true, detail: { message } }));
    const el = this.shadowRoot.querySelector(".err");
    if (el) el.textContent = message;
  }

  connectedCallback() {
    super.connectedCallback();
    if (this._wired) return;
    this._wired = true;
    this.shadowRoot.addEventListener("click", (e) => {
      const prov = e.target.closest(".provider");
      if (prov) { this._run({ method: "oauth", provider: prov.dataset.provider }); return; }
      const alt = e.target.closest(".alt button");
      if (alt) {
        this.setAttribute("mode", this.attr("mode", "password") === "magic" ? "password" : "magic");
      }
    });
    this.shadowRoot.addEventListener("submit", (e) => {
      e.preventDefault();
      const email = this.shadowRoot.querySelector("input[name=email]")?.value.trim();
      const password = this.shadowRoot.querySelector("input[name=password]")?.value;
      if (!email) return this._error("Enter your email.");
      const mode = this.attr("mode", "password");
      if (mode === "magic") this._run({ method: "magic", email });
      else this._run({ method: "password", email, password });
    });
  }

  render() {
    const heading = this.attr("heading", "Sign in");
    const mode = this.attr("mode", "password");
    const loading = this.attr("state") === "loading";
    const provs = this._providers()
      .map((p) => `<button class="provider" type="button" data-provider="${p.id}">
        ${GLYPHS[p.id] || fallbackGlyph}<span>Continue with ${p.name}</span></button>`)
      .join("");
    const submitInner = loading
      ? `<span class="spin"></span>`
      : mode === "magic" ? "Email me a magic link" : "Sign in";
    return `
      <div class="card" part="card">
        <h3>${heading}</h3>
        <p class="sub">Identity is a host capability — same surface, any provider behind the Dock.</p>
        <div class="providers">${provs}</div>
        <div class="div">or</div>
        <form>
          <div class="field">
            <label for="email">Email</label>
            <input id="email" name="email" type="email" placeholder="you@company.com" autocomplete="email" />
          </div>
          ${mode === "password" ? `
          <div class="field">
            <label for="password">Password</label>
            <input id="password" name="password" type="password" placeholder="••••••••" autocomplete="current-password" />
          </div>` : ""}
          <p class="err">${this._errMsg || ""}</p>
          <button class="submit" type="submit" part="submit">${submitInner}</button>
        </form>
        <p class="alt">${mode === "magic"
          ? `Prefer a password? <button type="button">Use password</button>`
          : `No password? <button type="button">Email a magic link</button>`}</p>
      </div>`;
  }
}

define("wb-auth", WbAuth);
