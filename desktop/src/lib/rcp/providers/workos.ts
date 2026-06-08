// The WorkOS provider — reframes the existing desktop WorkOS sign-in (network.rs
// loopback+PKCE, keychain-stored session) as ONE OidcTokenSource behind the
// generic OidcAdapter. WorkOS is no longer "the auth system" — it's an adapter.
// Swapping to BetterAuth/Clerk means swapping this file's TokenSource, nothing else.
//
// This is also the CLOUD target: a desktop client authing to a shared cloud
// runtime by WorkOS JWT (the org-shared-runtime story, wb-19b) — same RcpClient,
// different target than the local-tauri provider.

import { loadStoredSession, workosSignIn } from "$lib/bridge/network.svelte";
import { OidcAdapter, type OidcTokenSource } from "../adapters";
import { RcpClient } from "../client";
import type { RcpTarget } from "../types";

/** WorkOS session (keychain) as an OIDC token source. `renew` re-runs the
 *  interactive loopback sign-in against the broker. */
function workosTokenSource(brokerUrl: string): OidcTokenSource {
  const toTok = (s: { bearer: string; expires_at: number } | null) =>
    s ? { bearer: s.bearer, expiresAt: s.expires_at } : null;
  return {
    current: async () => toTok(await loadStoredSession()),
    renew: async () => toTok(await workosSignIn(brokerUrl)),
  };
}

/** AuthAdapter for the WorkOS-issued JWT (the oidc-jwt rung). */
export function workosAdapter(brokerUrl: string): OidcAdapter {
  return new OidcAdapter(workosTokenSource(brokerUrl));
}

/** An RCP client for a SHARED CLOUD runtime, authenticated by WorkOS JWT.
 *  `baseUrl` is the cloud runtime's URL (vs the local provider's discovery). */
export function cloudClient(baseUrl: string, brokerUrl: string): RcpClient {
  const target: RcpTarget = { getBaseUrl: () => baseUrl, auth: workosAdapter(brokerUrl) };
  return new RcpClient(target);
}
