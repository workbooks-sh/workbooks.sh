// Clerk-based device-flow auth for the brandnana CLI.
//
// Replaces the GitHub-only flow at ./cli.ts. Same shape:
//   1. CLI POSTs /v1/auth/cli/start (no auth) → { device_code, user_code, verification_url, expires_in_s, interval_s }
//   2. CLI opens browser to verification_url
//   3. Portal /cli/connect?code=<user_code> page shows Approve button (Clerk-gated)
//   4. Approve POST /v1/auth/cli/approve (Clerk JWT) binds user + mints key
//   5. CLI polls /v1/auth/cli/poll?device_code=... until status='approved'

import { Hono } from "hono";
import type { Bindings } from "../env.js";
import { mintKey } from "./keys.js";

const flow = new Hono<{ Bindings: Bindings }>();

const DEVICE_CODE_LEN = 32;
const USER_CODE_LEN = 8;
const TTL_MS = 10 * 60 * 1000; // 10 min
const POLL_INTERVAL_S = 3;

const VERIFY_URL_BASE = "https://app.brandnana.net/cli/connect";

function randomAlnum(len: number, alphabet: string): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  let out = "";
  for (const b of buf) out += alphabet[b % alphabet.length];
  return out;
}

const DEVICE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
const USER_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function makeUserCode(): string {
  // 8 chars formatted ABCD-1234 for readability
  const raw = randomAlnum(USER_CODE_LEN, USER_ALPHABET);
  return raw.slice(0, 4) + "-" + raw.slice(4);
}

// ── Clerk session JWT verify (real RS256 / JWKS) ─────────────────────────────
//
// Verify the JWT signature against Clerk's JWKS (fetched once, cached by `kid`)
// with Web Crypto, then check exp/nbf and require `sub`. The signature + expiry
// check IS the auth boundary — a forged/unsigned token cannot pass, and a
// missing `sid` no longer skips verification.

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

// Module-scope cache of imported CryptoKeys keyed by `kid`.
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

// Fetch Clerk's JWKS and (re)populate the cache, returning the key for `kid`.
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
): Promise<{ user_id: string; email: string | null }> {
  // Verify the RS256 signature + claims. This is the auth boundary.
  const payload = await verifyJwtSignature(secretKey, sessionJwt);
  const userId = payload.sub as string;

  // Defence-in-depth: if a session id is present, confirm it is live.
  if (payload.sid) {
    const r = await fetch(`https://api.clerk.com/v1/sessions/${payload.sid}`, {
      headers: { authorization: `Bearer ${secretKey}` },
    });
    if (!r.ok) throw new Error(`clerk_session_invalid_${r.status}`);
    const s = (await r.json()) as { status?: string; user_id?: string };
    if (s.status !== "active") throw new Error(`clerk_session_${s.status}`);
    if (s.user_id !== userId) throw new Error("clerk_session_user_mismatch");
  }
  const ur = await fetch(`https://api.clerk.com/v1/users/${userId}`, {
    headers: { authorization: `Bearer ${secretKey}` },
  });
  if (!ur.ok) throw new Error(`clerk_user_fetch_${ur.status}`);
  const u = (await ur.json()) as {
    email_addresses?: Array<{ email_address: string; id: string }>;
    primary_email_address_id?: string;
  };
  const primary = u.email_addresses?.find((e) => e.id === u.primary_email_address_id);
  return {
    user_id: userId,
    email: primary?.email_address ?? u.email_addresses?.[0]?.email_address ?? null,
  };
}

async function getOrCreateUser(env: Bindings, clerk_user_id: string, email: string | null): Promise<string> {
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

// ── POST /v1/auth/cli/start ─ no auth ────────────────────────────────────────

flow.post("/start", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    client_info?: Record<string, unknown>;
  };
  const deviceCode = randomAlnum(DEVICE_CODE_LEN, DEVICE_ALPHABET);
  const userCode = makeUserCode();
  const now = Date.now();
  const expires = now + TTL_MS;
  const clientInfoJson = body.client_info ? JSON.stringify(body.client_info).slice(0, 1024) : null;

  await c.env.DB.prepare(
    "INSERT INTO cli_device_codes (device_code, user_code, status, created_at, expires_at, client_info) VALUES (?, ?, 'pending', ?, ?, ?)",
  )
    .bind(deviceCode, userCode, now, expires, clientInfoJson)
    .run();

  return c.json({
    device_code: deviceCode,
    user_code: userCode,
    verification_url: `${VERIFY_URL_BASE}?code=${userCode}`,
    verification_url_complete: `${VERIFY_URL_BASE}?code=${userCode}`,
    expires_in_s: Math.floor(TTL_MS / 1000),
    interval_s: POLL_INTERVAL_S,
  });
});

// ── GET /v1/auth/cli/lookup?code=<user_code> ─ for portal Approve page ───────

flow.get("/lookup", async (c) => {
  const userCode = c.req.query("code")?.trim().toUpperCase();
  if (!userCode) return c.json({ error: "missing_code" }, 400);
  const row = await c.env.DB.prepare(
    "SELECT user_code, status, client_info, created_at, expires_at FROM cli_device_codes WHERE user_code = ? LIMIT 1",
  )
    .bind(userCode)
    .first<{ user_code: string; status: string; client_info: string | null; created_at: number; expires_at: number }>();
  if (!row) return c.json({ error: "code_not_found" }, 404);
  if (row.expires_at < Date.now() && row.status === "pending") {
    return c.json({ user_code: row.user_code, status: "expired" });
  }
  return c.json({
    user_code: row.user_code,
    status: row.status,
    client_info: row.client_info ? JSON.parse(row.client_info) : null,
    created_at: row.created_at,
    expires_at: row.expires_at,
  });
});

// ── POST /v1/auth/cli/approve ─ Clerk JWT in body ────────────────────────────

flow.post("/approve", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    clerk_session_jwt?: string;
    user_code?: string;
    decision?: "approve" | "deny";
  };
  const jwt = body.clerk_session_jwt;
  const userCode = body.user_code?.trim().toUpperCase();
  const decision = body.decision ?? "approve";
  if (!jwt || !userCode) return c.json({ error: "missing_inputs" }, 400);
  const secret = c.env.CLERK_SECRET_KEY;
  if (!secret) return c.json({ error: "clerk_not_configured" }, 503);

  let clerkUser: Awaited<ReturnType<typeof verifySessionJwt>>;
  try {
    clerkUser = await verifySessionJwt(secret, jwt);
  } catch (e) {
    return c.json({ error: "auth_failed", message: (e as Error).message }, 401);
  }

  const row = await c.env.DB.prepare(
    "SELECT device_code, status, expires_at FROM cli_device_codes WHERE user_code = ? LIMIT 1",
  )
    .bind(userCode)
    .first<{ device_code: string; status: string; expires_at: number }>();
  if (!row) return c.json({ error: "code_not_found" }, 404);
  if (row.expires_at < Date.now()) return c.json({ error: "code_expired" }, 410);
  if (row.status !== "pending") return c.json({ error: "code_already_resolved", status: row.status }, 409);

  if (decision === "deny") {
    await c.env.DB.prepare("UPDATE cli_device_codes SET status = 'denied', approved_at = ? WHERE user_code = ?")
      .bind(Date.now(), userCode)
      .run();
    return c.json({ ok: true, status: "denied" });
  }

  // Approve: ensure brandnana user, mint key, bind to device code.
  const user_id = await getOrCreateUser(c.env, clerkUser.user_id, clerkUser.email);
  const minted = await mintKey();
  const keyId = `ak-${crypto.randomUUID()}`;
  const now = Date.now();
  await c.env.DB.prepare(
    "INSERT INTO api_keys (id, user_id, hash, prefix, label, created_at, rate_limit_per_min) VALUES (?, ?, ?, ?, 'cli (brandnana login)', ?, 600)",
  )
    .bind(keyId, user_id, minted.hash, minted.prefix, now)
    .run();
  await c.env.DB.prepare(
    "UPDATE cli_device_codes SET status = 'approved', user_id = ?, api_key_id = ?, api_key_text = ?, approved_at = ? WHERE user_code = ?",
  )
    .bind(user_id, keyId, minted.cleartext, now, userCode)
    .run();

  return c.json({ ok: true, status: "approved", prefix: minted.prefix });
});

// ── GET /v1/auth/cli/poll?device_code=<…> ─ CLI polling ──────────────────────

flow.get("/poll", async (c) => {
  const deviceCode = c.req.query("device_code");
  if (!deviceCode) return c.json({ error: "missing_device_code" }, 400);
  const row = await c.env.DB.prepare(
    "SELECT user_code, status, api_key_text, expires_at FROM cli_device_codes WHERE device_code = ? LIMIT 1",
  )
    .bind(deviceCode)
    .first<{ user_code: string; status: string; api_key_text: string | null; expires_at: number }>();
  if (!row) return c.json({ error: "device_code_not_found" }, 404);
  if (row.expires_at < Date.now() && row.status === "pending") {
    await c.env.DB.prepare("UPDATE cli_device_codes SET status = 'expired' WHERE device_code = ?")
      .bind(deviceCode)
      .run();
    return c.json({ status: "expired" });
  }
  if (row.status === "approved" && row.api_key_text) {
    // Mark consumed + return cleartext exactly once.
    await c.env.DB.prepare("UPDATE cli_device_codes SET status = 'consumed', api_key_text = NULL, consumed_at = ? WHERE device_code = ?")
      .bind(Date.now(), deviceCode)
      .run();
    return c.json({ status: "approved", api_key: row.api_key_text });
  }
  return c.json({ status: row.status, user_code: row.user_code });
});

export default flow;
