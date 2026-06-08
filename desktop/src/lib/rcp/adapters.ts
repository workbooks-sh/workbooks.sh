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

/** Placeholder for the OIDC rung (implemented in wb-kco). Declares the contract
 *  so url/cloud targets can type against it now. */
export interface OidcConfig {
  issuer: string;
  clientId: string;
  /** Where the IDP redirects after auth (loopback for desktop, route for web). */
  redirectUri: string;
  scopes?: string[];
}
