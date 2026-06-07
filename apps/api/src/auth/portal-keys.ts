// Clerk-session → brandnana API key bridge.
//
// The portal needs to mint a brandnana API key on the user's behalf so it
// can be displayed in /app/keys, copied into the user's CLI, etc.
//
// Flow:
//   1. Portal page collects a Clerk session JWT (clerk.session.getToken()).
//   2. POSTs it to /v1/auth/portal/keys (no bearer — Clerk JWT IS the auth).
//   3. This handler verifies the JWT's RS256 signature against Clerk's JWKS
//      (fetched from GET https://api.clerk.com/v1/jwks, cached in module scope
//      by `kid`), checks `exp`/`nbf`, requires `sub`, then upserts a users row
//      keyed by the Clerk user id, mints a fresh adk_live_* key, and returns
//      the cleartext exactly once.
//
// SECURITY: the signature + expiry check IS the auth boundary. We do NOT trust
// any unsigned/decoded claims. When the token carries a `sid` we additionally
// confirm the session is live via /v1/sessions/{sid}, but a missing `sid` no
// longer skips verification.
//
// We can ALSO use the same handler to list / revoke existing keys.

import { Hono } from "hono";
import type { Bindings } from "../env.js";
import { mintKey } from "./keys.js";

const portal = new Hono<{ Bindings: Bindings }>();

// ── Clerk JWT verify (real RS256 / JWKS, no @clerk/backend dep) ──────────────
//
// We fetch Clerk's JWKS (RSA public keys) once and cache by `kid`, then verify
// the JWT signature with Web Crypto. This is the authentication boundary — a
// forged/unsigned token cannot pass.

interface ClerkUserResponse {
  id: string;
  email_addresses?: Array<{ email_address: string; id: string }>;
  primary_email_address_id?: string;
  first_name?: string | null;
  last_name?: string | null;
}

interface ClerkJwk {
  kid: string;
  kty: string;
  n: string;
  e: string;
  alg?: string;
}

interface ClerkJwtHeader {
  alg?: string;
  kid?: string;
  typ?: string;
}

interface ClerkJwtPayload {
  sub?: string;
  sid?: string;
  exp?: number;
  nbf?: number;
}

// Module-scope cache of imported CryptoKeys keyed by `kid`. JWKS rotate rarely;
// on a cache miss (unknown kid) we re-fetch the whole set.
const jwksKeyCache = new Map<string, CryptoKey>();

function base64UrlToBytes(b64url: string): Uint8Array {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function base64UrlDecodeJson<T>(b64url: string): T {
  const bytes = base64UrlToBytes(b64url);
  return JSON.parse(new TextDecoder().decode(bytes)) as T;
}

async function importJwk(jwk: ClerkJwk): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "jwk",
    { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
}

// Fetch Clerk's JWKS and (re)populate the module-scope cache, returning the key
// for `kid`. Called on cache miss only.
async function fetchAndCacheKey(secretKey: string, kid: string): Promise<CryptoKey> {
  const r = await fetch("https://api.clerk.com/v1/jwks", {
    headers: { authorization: `Bearer ${secretKey}` },
  });
  if (!r.ok) throw new Error(`clerk_jwks_fetch_${r.status}`);
  const data = (await r.json()) as { keys?: ClerkJwk[] };
  const keys = data.keys ?? [];
  let match: CryptoKey | null = null;
  for (const jwk of keys) {
    if (jwk.kty !== "RSA" || !jwk.kid) continue;
    const imported = await importJwk(jwk);
    jwksKeyCache.set(jwk.kid, imported);
    if (jwk.kid === kid) match = imported;
  }
  if (!match) throw new Error("unknown_kid");
  return match;
}

// Verify the JWT signature + claims (exp/nbf/sub). This is the security
// boundary. On success returns the verified payload.
async function verifyJwtSignature(secretKey: string, jwt: string): Promise<ClerkJwtPayload> {
  const parts = jwt.split(".");
  if (parts.length !== 3) throw new Error("invalid_jwt");
  const [headerB64, payloadB64, sigB64] = parts as [string, string, string];

  let header: ClerkJwtHeader;
  try {
    header = base64UrlDecodeJson<ClerkJwtHeader>(headerB64);
  } catch {
    throw new Error("invalid_jwt_header");
  }
  if (header.alg !== "RS256") throw new Error("unsupported_alg");
  if (!header.kid) throw new Error("missing_kid");

  let key = jwksKeyCache.get(header.kid);
  if (!key) key = await fetchAndCacheKey(secretKey, header.kid);

  const signature = base64UrlToBytes(sigB64);
  const signed = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const ok = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    signature,
    signed,
  );
  if (!ok) throw new Error("invalid_signature");

  let payload: ClerkJwtPayload;
  try {
    payload = base64UrlDecodeJson<ClerkJwtPayload>(payloadB64);
  } catch {
    throw new Error("invalid_jwt_payload");
  }
  const nowSec = Math.floor(Date.now() / 1000);
  if (typeof payload.exp === "number" && payload.exp <= nowSec) throw new Error("token_expired");
  if (typeof payload.nbf === "number" && payload.nbf > nowSec) throw new Error("token_not_yet_valid");
  if (!payload.sub) throw new Error("missing_sub");
  return payload;
}

async function verifySessionJwt(
  secretKey: string,
  sessionJwt: string,
): Promise<{ user_id: string; email: string | null; first_name: string | null; last_name: string | null }> {
  // Verify the RS256 signature + claims. This is the auth boundary.
  const payload = await verifyJwtSignature(secretKey, sessionJwt);
  const userId = payload.sub as string;

  // When the token carries a session id, additionally confirm the session is
  // live via Clerk's backend API. (Optional defence-in-depth — a missing `sid`
  // no longer skips verification, because the signature check already gated us.)
  if (payload.sid) {
    const r = await fetch(`https://api.clerk.com/v1/sessions/${payload.sid}`, {
      headers: { authorization: `Bearer ${secretKey}` },
    });
    if (!r.ok) throw new Error(`clerk_session_invalid_${r.status}`);
    const s = (await r.json()) as { status?: string; user_id?: string };
    if (s.status !== "active") throw new Error(`clerk_session_${s.status}`);
    if (s.user_id !== userId) throw new Error("clerk_session_user_mismatch");
  }

  // Fetch user details (email, name).
  const ur = await fetch(`https://api.clerk.com/v1/users/${userId}`, {
    headers: { authorization: `Bearer ${secretKey}` },
  });
  if (!ur.ok) throw new Error(`clerk_user_fetch_${ur.status}`);
  const u = (await ur.json()) as ClerkUserResponse;
  const primaryId = u.primary_email_address_id;
  const email =
    u.email_addresses?.find((e) => e.id === primaryId)?.email_address ??
    u.email_addresses?.[0]?.email_address ??
    null;
  return {
    user_id: userId,
    email,
    first_name: u.first_name ?? null,
    last_name: u.last_name ?? null,
  };
}

async function getOrCreateUser(
  env: Bindings,
  clerk_user_id: string,
  email: string | null,
): Promise<string> {
  // Look up by clerk_user_id mapping (stored as github_login for v1 — yes,
  // the column name is now misleading; a follow-up migration will rename it
  // to external_id). The unique constraint already enforces one user per
  // clerk_user_id.
  const existing = await env.DB.prepare(
    "SELECT id FROM users WHERE github_login = ? LIMIT 1",
  )
    .bind(clerk_user_id)
    .first<{ id: string }>();
  if (existing) return existing.id;

  const id = crypto.randomUUID();
  const now = Date.now();
  await env.DB.prepare(
    "INSERT INTO users (id, github_login, email, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
  )
    .bind(id, clerk_user_id, email, now, now)
    .run();
  return id;
}

// ── POST /v1/auth/portal/keys ─ mint a fresh key ─────────────────────────────

portal.post("/keys", async (c) => {
  try {
    const body = (await c.req.json().catch(() => ({}))) as {
      clerk_session_jwt?: string;
      label?: string;
    };
    const jwt = body.clerk_session_jwt;
    if (!jwt) return c.json({ error: "missing_clerk_session_jwt" }, 400);
    const secret = c.env.CLERK_SECRET_KEY;
    if (!secret) return c.json({ error: "clerk_not_configured" }, 503);

    let clerkUser: Awaited<ReturnType<typeof verifySessionJwt>>;
    try {
      clerkUser = await verifySessionJwt(secret, jwt);
    } catch (e) {
      return c.json({ error: "auth_failed", message: (e as Error).message }, 401);
    }

    let user_id: string;
    try {
      user_id = await getOrCreateUser(c.env, clerkUser.user_id, clerkUser.email);
    } catch (e) {
      return c.json({ error: "user_upsert_failed", message: (e as Error).message }, 502);
    }

    const minted = await mintKey();
    const id = `ak-${crypto.randomUUID()}`;
    const label = (body.label?.slice(0, 80) ?? "portal").trim() || "portal";
    const now = Date.now();
    try {
      await c.env.DB.prepare(
        "INSERT INTO api_keys (id, user_id, hash, prefix, label, created_at, rate_limit_per_min) VALUES (?, ?, ?, ?, ?, ?, 600)",
      )
        .bind(id, user_id, minted.hash, minted.prefix, label, now)
        .run();
    } catch (e) {
      return c.json({ error: "key_insert_failed", message: (e as Error).message }, 502);
    }

    return c.json({
      ok: true,
      id,
      prefix: minted.prefix,
      label,
      created_at: now,
      cleartext: minted.cleartext,
      rate_limit_per_min: 600,
    });
  } catch (e) {
    return c.json({ error: "unexpected", message: (e as Error).message }, 500);
  }
});

// ── GET /v1/auth/portal/keys ─ list (no cleartext) ───────────────────────────

portal.get("/keys", async (c) => {
  const jwt = c.req.header("x-clerk-session-jwt");
  if (!jwt) return c.json({ error: "missing_clerk_session_jwt" }, 400);
  const secret = c.env.CLERK_SECRET_KEY;
  if (!secret) return c.json({ error: "clerk_not_configured" }, 503);

  let clerkUser: Awaited<ReturnType<typeof verifySessionJwt>>;
  try {
    clerkUser = await verifySessionJwt(secret, jwt);
  } catch (e) {
    return c.json({ error: "auth_failed", message: (e as Error).message }, 401);
  }
  const user_id = await getOrCreateUser(c.env, clerkUser.user_id, clerkUser.email);

  const rows = await c.env.DB.prepare(
    "SELECT id, prefix, label, created_at, last_used_at, revoked_at, rate_limit_per_min FROM api_keys WHERE user_id = ? ORDER BY created_at DESC",
  )
    .bind(user_id)
    .all<{ id: string; prefix: string; label: string | null; created_at: number; last_used_at: number | null; revoked_at: number | null; rate_limit_per_min: number }>();

  return c.json({
    user: { id: user_id, email: clerkUser.email, first_name: clerkUser.first_name, last_name: clerkUser.last_name },
    keys: rows.results ?? [],
  });
});

// ── DELETE /v1/auth/portal/keys/:id ─ revoke ─────────────────────────────────

portal.delete("/keys/:id", async (c) => {
  const jwt = c.req.header("x-clerk-session-jwt");
  if (!jwt) return c.json({ error: "missing_clerk_session_jwt" }, 400);
  const secret = c.env.CLERK_SECRET_KEY;
  if (!secret) return c.json({ error: "clerk_not_configured" }, 503);
  let clerkUser: Awaited<ReturnType<typeof verifySessionJwt>>;
  try {
    clerkUser = await verifySessionJwt(secret, jwt);
  } catch (e) {
    return c.json({ error: "auth_failed", message: (e as Error).message }, 401);
  }
  const user_id = await getOrCreateUser(c.env, clerkUser.user_id, clerkUser.email);
  const keyId = c.req.param("id");
  const r = await c.env.DB.prepare(
    "UPDATE api_keys SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
  )
    .bind(Date.now(), keyId, user_id)
    .run();
  if (!r.meta.changes) return c.json({ error: "not_found_or_already_revoked" }, 404);
  return c.json({ ok: true, id: keyId });
});

export default portal;
