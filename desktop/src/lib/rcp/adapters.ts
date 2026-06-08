// RCP auth adapters — the pluggable IDP seam (§2). PORTABLE (no Tauri/Svelte).
//
// Swapping the adapter is the ONLY work to change how a client authenticates:
//   trusted rung  → LocalTokenAdapter (local discovery token) or AnonAdapter
//   oidc-jwt rung → OidcAdapter (wb-kco) — WorkOS/BetterAuth/Clerk are configs of it

import type { AuthAdapter } from "./types";

/** Anonymous. Valid only against single-tenant `trusted` runtimes. */
export class AnonAdapter implements AuthAdapter {
  async getToken(): Promise<string | null> {
    return null;
  }
}

/** The per-boot discovery token (the `trusted` rung). The token getter is
 *  injected so this file stays free of Tauri/Svelte — the local-tauri provider
 *  passes `() => sidecar.status.token`. */
export class LocalTokenAdapter implements AuthAdapter {
  #get: () => string | null;
  constructor(get: () => string | null) {
    this.#get = get;
  }
  async getToken(): Promise<string | null> {
    return this.#get();
  }
}

export interface OidcConfig {
  issuer: string;
  clientId: string;
  /** Where the IDP redirects after auth (loopback for desktop, route for web). */
  redirectUri: string;
  scopes?: string[];
}

/** A cached JWT from an IDP, with its expiry (epoch SECONDS). */
export interface OidcToken {
  bearer: string;
  expiresAt: number;
}

/** Supplies + (optionally) renews an IDP-issued JWT. The PLATFORM provides this:
 *  desktop reads the keychain session (WorkOS loopback+PKCE in network.rs); a web
 *  app runs an in-page PKCE flow. The adapter logic — expiry + renew — is shared. */
export interface OidcTokenSource {
  /** Current cached token, or null if none. */
  current(): Promise<OidcToken | null>;
  /** Re-authenticate (interactive) and return a fresh token. Optional. */
  renew?(): Promise<OidcToken | null>;
}

/** The `oidc-jwt` rung. Returns a non-expired JWT, renewing if the source can.
 *  WorkOS / BetterAuth / Clerk are just different OidcTokenSources behind this —
 *  switching IDP never touches the client transport (RUNTIME-CONNECT-PROTOCOL §2). */
export class OidcAdapter implements AuthAdapter {
  #src: OidcTokenSource;
  #skewSec: number;
  constructor(src: OidcTokenSource, opts: { clockSkewSec?: number } = {}) {
    this.#src = src;
    this.#skewSec = opts.clockSkewSec ?? 30;
  }
  async getToken(): Promise<string | null> {
    const now = Math.floor(Date.now() / 1000) + this.#skewSec;
    let tok = await this.#src.current();
    if ((!tok || tok.expiresAt <= now) && this.#src.renew) {
      tok = await this.#src.renew();
    }
    return tok && tok.expiresAt > now ? tok.bearer : null;
  }
}
