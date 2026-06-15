// workponents · auth domain — the identity seam.
//
// The reinvention: identity is a HOST capability, not a per-provider widget.
// The elements never know whether the session is backed by Clerk, Auth0, WorkOS,
// or BetterAuth — those are server-side wirings behind the Dock. The elements
// read ONE small `auth` capability layered on `this.host`:
//
//   • session()           → current { user, providers } | { user: null, providers }
//   • signIn({method, provider, email, password})  → resolves a session
//   • signOut()           → clears the session
//   • subscribe(fn)        → notified on every session change (fn(session))
//
// This file implements that seam OVER the existing Host (`src/core/host.js`),
// WITHOUT editing core. When a runtime URL is configured it routes to the
// runtime's `/auth/*` endpoints (provider-agnostic — the runtime resolves the
// real provider); standalone (no runtime), a MOCK identity lets the elements
// render + demo a full sign-in → authed → sign-out cycle with no backend.
//
// SUGGESTED CORE ADDITION (noted, not made): a first-class `host.auth` accessor
// returning an `AuthCapability` so every domain shares ONE identity instance and
// the seam isn't re-created per element family. Until then we cache a singleton
// here, keyed off the active Host.
//
// Host endpoint contract (provider-agnostic, the runtime wires the provider):
//   GET  /auth/session                 → { user, providers }
//   POST /auth/signin  {method, provider, email?, password?}  → { user, providers }
//   POST /auth/signout                 → { user: null, providers }
// where  user = { id, name, email, avatar?, roles?: string[] } | null
//        providers = [{ id, name }]   (the sign-in options the surface renders)

import { getHost } from "../../core/host.js";

/** The default provider list a mock/preview identity offers. */
export const DEFAULT_PROVIDERS = [
  { id: "google", name: "Google" },
  { id: "github", name: "GitHub" },
  { id: "workos", name: "SSO" },
];

/** A live identity capability bound to a Host (real) or a mock (standalone). */
export class AuthCapability extends EventTarget {
  /** @param {{ host?: any, mock?: boolean, providers?: any[], seed?: any }} [opts] */
  constructor(opts = {}) {
    super();
    this._host = opts.host || null;
    // Mock when explicitly asked OR when no runtime backs the Host.
    this._mock = opts.mock != null ? opts.mock : !(this._host && this._host.available?.("auth"));
    this._providers = opts.providers || DEFAULT_PROVIDERS;
    this._user = opts.seed?.user || null;
    this._loaded = false;
  }

  get isMock() {
    return this._mock;
  }

  /** Current session snapshot. Loads once from the Host when real. */
  async session() {
    if (this._mock) return this._snapshot();
    if (!this._loaded) {
      try {
        const s = await this._host.request("/auth/session", { method: "GET" });
        this._user = s?.user ?? null;
        if (Array.isArray(s?.providers)) this._providers = s.providers;
      } catch {
        // Runtime unreachable → fall back to a preview identity, don't throw.
        this._mock = true;
      }
      this._loaded = true;
    }
    return this._snapshot();
  }

  /** The synchronous best-known session (no fetch); elements seed UI with this. */
  peek() {
    return this._snapshot();
  }

  /**
   * Resolve a sign-in. method = "oauth" (with provider) | "password" | "magic".
   * Real: POSTs /auth/signin. Mock: fabricates a plausible session.
   */
  async signIn({ method = "password", provider = null, email = null, password = null } = {}) {
    if (this._mock) {
      const name = method === "oauth"
        ? this._providerName(provider)
        : (email ? email.split("@")[0] : "You");
      this._user = {
        id: "mock-" + (provider || method),
        name: this._titleize(name),
        email: email || (provider ? `you@${provider}.example` : "you@example.com"),
        avatar: null,
        roles: ["member"],
        via: provider || method,
      };
      return this._change();
    }
    const s = await this._host.request("/auth/signin", {
      body: { method, provider, email, password },
    });
    this._user = s?.user ?? null;
    if (Array.isArray(s?.providers)) this._providers = s.providers;
    return this._change();
  }

  /** Magic-link request — mock resolves immediately; real returns a pending hint. */
  async requestMagicLink({ email } = {}) {
    if (this._mock) return this.signIn({ method: "magic", email });
    return this._host.request("/auth/signin", { body: { method: "magic", email } });
  }

  async signOut() {
    if (!this._mock) {
      try { await this._host.request("/auth/signout", {}); } catch { /* clear locally regardless */ }
    }
    this._user = null;
    return this._change();
  }

  /** Subscribe to session changes; returns an unsubscribe fn. */
  subscribe(fn) {
    const h = (e) => fn(e.detail);
    this.addEventListener("change", h);
    return () => this.removeEventListener("change", h);
  }

  get providers() {
    return this._providers;
  }

  _snapshot() {
    return { user: this._user ? { ...this._user } : null, providers: this._providers };
  }

  _change() {
    const snap = this._snapshot();
    this.dispatchEvent(new CustomEvent("change", { detail: snap }));
    return snap;
  }

  _providerName(id) {
    return this._providers.find((p) => p.id === id)?.name || id || "Account";
  }

  _titleize(s) {
    return String(s).replace(/(^|[\s._-])(\w)/g, (_, sep, c) => (sep ? " " : "") + c.toUpperCase());
  }
}

// One identity per active Host (until core grows a `host.auth`). A page/workbook
// can override with configureIdentity() to force a mock or seed a session.
let _identity = null;

/** Configure the shared identity (call once; e.g. a demo seeds a mock). */
export function configureIdentity(opts = {}) {
  _identity = new AuthCapability({ host: opts.host || getHost(), ...opts });
  return _identity;
}

/** The shared identity capability (auto-created over the active Host). */
export function getIdentity() {
  if (!_identity) _identity = new AuthCapability({ host: getHost() });
  return _identity;
}
