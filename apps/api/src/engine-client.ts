// Workbooks Engine client — mints per-tenant Engine bearer tokens and builds
// the Authorization header used when the worker calls the engine (loopback).
//
// SECURITY (multi-tenant): the engine runs WB_TENANCY_MODE=multi + ISOLATION=pool.
// In that posture the static WB_PUBLIC_BEARER binds NO tenant and must NOT be the
// tenant source — the engine rejects a bare static bearer on tenant-touching routes
// (see runtime/engine .../auth_plug.ex). The forgery-proof tenant source is a
// TenantToken: HMAC-SHA256 over a canonical payload that bakes in the tenant id.
//
// This module ports the engine's wire format VERBATIM so a token minted here
// verifies byte-for-byte against the Elixir verifier:
//   runtime/engine/lib/workbooks_runtime/api/tenant_token.ex (mint :34-45, verify :52-69)
//
// Wire format (must byte-match tenant_token.ex):
//   token   = base64url(payload) "." base64url(HMAC_SHA256(key, base64url(payload)))
//   payload = `{"t":` + JSON.stringify(tenant_id) + `,"exp":` + exp + `}`
//             — canonical: fixed key order ("t" then "exp"), NO whitespace
//   exp     = unix SECONDS, now + ttlSeconds (default 900, tenant_token.ex:26)
//   base64url is UNPADDED. The MAC is computed over the base64url payload TEXT
//   (the ASCII bytes of p64), NOT over the raw payload bytes.
//   key     = WB_TENANT_TOKEN_KEY — the SAME secret value live on bn-engine.
//
// Runs on Cloudflare Workers → Web Crypto (crypto.subtle), no Node Buffer.

import type { Bindings } from "./env.js";

/** Engine TenantToken default lifetime, in seconds (tenant_token.ex:26 @default_ttl_seconds). */
export const TENANT_TOKEN_DEFAULT_TTL_SECONDS = 900;

/** Minimum key length the engine accepts (tenant_token.ex:79 `byte_size(k) >= 16`). */
const MIN_KEY_BYTES = 16;

/**
 * Tenant slug regex — MUST match the engine's @tenant_slug_re
 * (tenant_token.ex:25): `\A[a-z0-9][a-z0-9_-]{0,127}\z`. A token whose `t` fails
 * this is rejected at verify (test T10), so we reject at mint to fail fast and
 * never emit a token the engine will refuse.
 */
const TENANT_SLUG_RE = /^[a-z0-9][a-z0-9_-]{0,127}$/;

/** Bytes → unpadded base64url (RFC 4648 §5: + → -, / → _, no `=` padding). */
function base64UrlEncode(bytes: Uint8Array): string {
  // btoa needs a binary string; build it without spreading (avoids call-stack
  // limits on large inputs — payloads/MACs here are tiny but keep it safe).
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i] as number);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Import a raw secret as an HMAC-SHA256 signing key. */
async function importHmacKey(key: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/**
 * Mint a signed Engine TenantToken for `tenantId`.
 *
 * Byte-exact port of `WorkbooksRuntime.Api.TenantToken.mint/2` so the engine
 * verifier accepts it (tests T4-T10 on the engine side rely on this).
 *
 * @param tenantId  tenant slug — must match `^[a-z0-9][a-z0-9_-]{0,127}$`.
 * @param key       WB_TENANT_TOKEN_KEY — the same secret live on bn-engine; >= 16 bytes.
 * @param ttlSeconds token lifetime; default 900s (15 min). `exp = now + ttlSeconds`.
 * @returns the wire token `p64 + "." + m64`.
 * @throws Error("no_key") if the key is missing/too short (mirrors {:error, :no_key}).
 * @throws Error("bad_tenant") if the slug is invalid (mirrors {:error, :bad_tenant}).
 */
export async function mintTenantToken(
  tenantId: string,
  key: string | undefined,
  ttlSeconds: number = TENANT_TOKEN_DEFAULT_TTL_SECONDS,
): Promise<string> {
  if (typeof key !== "string" || new TextEncoder().encode(key).length < MIN_KEY_BYTES) {
    throw new Error("no_key");
  }
  if (!TENANT_SLUG_RE.test(tenantId)) {
    throw new Error("bad_tenant");
  }

  const exp = Math.floor(Date.now() / 1000) + ttlSeconds;

  // Canonical serialization — fixed key order, NO whitespace — so this matches
  // tenant_token.ex:40 byte-for-byte. JSON.stringify(tenantId) yields the JSON
  // string literal (quoted, escaped) exactly like Jason.encode!/1 does for a
  // binary; Integer.to_string(exp) has no decimals/sign for a positive unix ts,
  // matching `${exp}` here.
  const payload = `{"t":${JSON.stringify(tenantId)},"exp":${exp}}`;

  const p64 = base64UrlEncode(new TextEncoder().encode(payload));

  // MAC is over the base64url payload TEXT (ASCII bytes of p64), not raw payload —
  // tenant_token.ex:42 `:crypto.mac(:hmac, :sha256, key, p64)`.
  const cryptoKey = await importHmacKey(key);
  const macBuf = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(p64));
  const m64 = base64UrlEncode(new Uint8Array(macBuf));

  return `${p64}.${m64}`;
}

/**
 * Build the `Authorization` bearer header value the worker uses when it calls
 * the engine (loopback) on behalf of `tenantId`.
 *
 * Returns `"Bearer <minted-TenantToken>"`. The minted token IS the per-request
 * engine bearer — it is what the SHARED CONTRACT calls WB_ENGINE_BEARER when the
 * engine spawns an agent session, and what the worker presents directly here.
 *
 * In single/desktop mode the engine accepts the static WB_PUBLIC_BEARER; in
 * multi mode (the live bn-engine posture) only this minted token binds a tenant.
 */
export async function engineBearerHeader(
  env: Pick<Bindings, "WB_TENANT_TOKEN_KEY">,
  tenantId: string,
  ttlSeconds: number = TENANT_TOKEN_DEFAULT_TTL_SECONDS,
): Promise<{ Authorization: string }> {
  const token = await mintTenantToken(tenantId, env.WB_TENANT_TOKEN_KEY, ttlSeconds);
  return { Authorization: `Bearer ${token}` };
}
