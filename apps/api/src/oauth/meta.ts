// Meta (Facebook) OAuth flow.
//
// Standard server-side code grant — three steps:
//
//   1. CLI hits POST /auth/meta/start with bearer. Server creates a
//      pending_oauth_sessions row scoped to the authed user, returns
//      `{ auth_url, session_id, expires_at }`. CLI opens auth_url.
//   2. Meta redirects to /auth/meta/callback?code=…&state=<session_id>.
//      Server exchanges code → short-lived token → long-lived (60d)
//      token, writes provider_connections row, marks the session
//      'connected', and shows a "you can close this tab" HTML page.
//   3. CLI polls GET /auth/meta/status?session=<id> until status is
//      'connected' (or 'error' or expired), then drops the user back
//      to a working `brandnana ads sync --source meta`.
//
// Scopes requested: ads_read (read campaigns/ads/creatives) +
// pages_show_list (list managed Pages for UX context). Add read_insights
// if performance metrics are wanted later.
//
// Docs: https://developers.facebook.com/docs/facebook-login/guides/access-tokens

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";

const GRAPH = "https://graph.facebook.com/v22.0";
const META_DIALOG = "https://www.facebook.com/v22.0/dialog/oauth";
const REQUESTED_SCOPES = ["ads_read", "pages_show_list"].join(",");
const SESSION_TTL_MS = 15 * 60 * 1000; // 15 minutes for the user to finish the dance

const meta = new Hono<{ Bindings: Bindings }>();

function redirectUri(c: { req: { url: string } }): string {
  const url = new URL(c.req.url);
  return `${url.origin}/auth/meta/callback`;
}

// POST /auth/meta/start
// Authed. Creates a pending session and returns the auth_url to open.
meta.post("/start", requireBearer, async (c) => {
  const env = c.env;
  if (!env.META_CLIENT_ID || !env.META_CLIENT_SECRET) {
    return c.json(
      {
        error: "not_configured",
        message:
          "META_CLIENT_ID + META_CLIENT_SECRET must be set as worker secrets. " +
          "Add the redirect URI to facebook.com/apps/<id>/fb-login/settings (Valid OAuth Redirect URIs).",
      },
      503,
    );
  }
  const user = c.get("user");
  const id = crypto.randomUUID();
  const now = Date.now();
  const expiresAt = now + SESSION_TTL_MS;

  await env.DB.prepare(
    `INSERT INTO pending_oauth_sessions (id, user_id, provider, status, created_at, expires_at)
     VALUES (?, ?, 'meta', 'pending', ?, ?)`,
  )
    .bind(id, user.id, now, expiresAt)
    .run();

  const auth = new URL(META_DIALOG);
  auth.searchParams.set("client_id", env.META_CLIENT_ID);
  auth.searchParams.set("redirect_uri", redirectUri(c));
  auth.searchParams.set("scope", REQUESTED_SCOPES);
  auth.searchParams.set("state", id);
  auth.searchParams.set("response_type", "code");

  return c.json({
    session_id: id,
    auth_url: auth.toString(),
    expires_at: expiresAt,
    scopes: REQUESTED_SCOPES,
  });
});

// GET /auth/meta/callback?code=…&state=<session_id>
// Unauthenticated (Meta calls this). Exchanges code → tokens, writes
// provider_connections row, marks the session connected.
meta.get("/callback", async (c) => {
  const url = new URL(c.req.url);
  const allParams: Record<string, string> = {};
  for (const [k, v] of url.searchParams) allParams[k] = v;

  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  // Meta sends OAuth errors in several shapes — capture them all.
  const errorParam =
    url.searchParams.get("error") ??
    url.searchParams.get("error_code") ??
    url.searchParams.get("error_reason");
  const errorDesc =
    url.searchParams.get("error_description") ?? url.searchParams.get("error_message");

  if (errorParam) {
    const detail = errorDesc ? `${errorParam}: ${errorDesc}` : errorParam;
    if (state) await markSessionError(c.env, state, detail);
    return c.html(errorPage(`Meta returned: ${detail}`), 400);
  }
  if (!code || !state) {
    // Echo back everything we received so we can diagnose silently-empty redirects.
    const debug =
      Object.keys(allParams).length === 0 ? "(no query params)" : JSON.stringify(allParams);
    return c.html(errorPage(`Missing code or state from Meta. Got: ${debug}`), 400);
  }

  const session = await c.env.DB.prepare(
    "SELECT id, user_id, expires_at FROM pending_oauth_sessions WHERE id = ? AND provider = 'meta'",
  )
    .bind(state)
    .first<{ id: string; user_id: string; expires_at: number }>();

  if (!session) {
    return c.html(errorPage("Unknown OAuth session — try `brandnana auth meta` again."), 400);
  }
  if (Date.now() > session.expires_at) {
    await markSessionError(c.env, state, "expired");
    return c.html(errorPage("OAuth session expired — try `brandnana auth meta` again."), 400);
  }

  try {
    const tokens = await exchangeCodeForLongLivedToken(c.env, code, redirectUri(c));
    const profile = await fetchMetaUser(tokens.access_token);
    const connection = await upsertConnection(c.env, {
      userId: session.user_id,
      accountId: profile.id,
      accountName: profile.name,
      accessToken: tokens.access_token,
      tokenType: tokens.token_type,
      expiresAt: tokens.expires_at,
      scope: tokens.scope,
      raw: { profile, tokens },
    });
    await c.env.DB.prepare(
      "UPDATE pending_oauth_sessions SET status = 'connected', connection_id = ? WHERE id = ?",
    )
      .bind(connection.id, state)
      .run();
    return c.html(successPage(profile.name));
  } catch (e) {
    const msg = (e as Error).message;
    await markSessionError(c.env, state, msg);
    return c.html(errorPage(`Token exchange failed: ${msg}`), 500);
  }
});

// GET /auth/meta/status?session=<id>
// Authed. Returns the current state of the OAuth dance.
meta.get("/status", requireBearer, async (c) => {
  const id = c.req.query("session");
  if (!id) return c.json({ error: "missing_session" }, 400);
  const user = c.get("user");
  const row = await c.env.DB.prepare(
    `SELECT id, provider, status, connection_id, error, expires_at
       FROM pending_oauth_sessions
      WHERE id = ? AND user_id = ?`,
  )
    .bind(id, user.id)
    .first<{
      id: string;
      provider: string;
      status: string;
      connection_id: string | null;
      error: string | null;
      expires_at: number;
    }>();
  if (!row) return c.json({ error: "unknown_session" }, 404);
  return c.json({
    session_id: row.id,
    provider: row.provider,
    state: row.status,
    error: row.error,
    expires_at: row.expires_at,
  });
});

// -- helpers --------------------------------------------------------------

interface TokenExchangeResult {
  access_token: string;
  token_type: string;
  expires_at: number | null;
  scope: string | null;
}

async function exchangeCodeForLongLivedToken(
  env: Bindings,
  code: string,
  redirect: string,
): Promise<TokenExchangeResult> {
  if (!env.META_CLIENT_ID || !env.META_CLIENT_SECRET) {
    throw new Error("META_CLIENT_ID / META_CLIENT_SECRET not configured");
  }
  // Short-lived (~1h) token.
  const shortUrl = new URL(`${GRAPH}/oauth/access_token`);
  shortUrl.searchParams.set("client_id", env.META_CLIENT_ID);
  shortUrl.searchParams.set("client_secret", env.META_CLIENT_SECRET);
  shortUrl.searchParams.set("redirect_uri", redirect);
  shortUrl.searchParams.set("code", code);
  const shortRes = await fetch(shortUrl.toString());
  if (!shortRes.ok) {
    throw new Error(`short-token exchange ${shortRes.status}: ${await shortRes.text()}`);
  }
  const shortBody = (await shortRes.json()) as {
    access_token?: string;
    token_type?: string;
    error?: { message?: string };
  };
  if (!shortBody.access_token) {
    throw new Error(`short-token exchange: ${shortBody.error?.message ?? "no access_token"}`);
  }

  // Long-lived (~60d) token.
  const longUrl = new URL(`${GRAPH}/oauth/access_token`);
  longUrl.searchParams.set("grant_type", "fb_exchange_token");
  longUrl.searchParams.set("client_id", env.META_CLIENT_ID);
  longUrl.searchParams.set("client_secret", env.META_CLIENT_SECRET);
  longUrl.searchParams.set("fb_exchange_token", shortBody.access_token);
  const longRes = await fetch(longUrl.toString());
  if (!longRes.ok) {
    throw new Error(`long-token exchange ${longRes.status}: ${await longRes.text()}`);
  }
  const longBody = (await longRes.json()) as {
    access_token?: string;
    token_type?: string;
    expires_in?: number;
  };
  if (!longBody.access_token) {
    throw new Error("long-token exchange returned no access_token");
  }
  const expiresAt = longBody.expires_in ? Date.now() + longBody.expires_in * 1000 : null;
  return {
    access_token: longBody.access_token,
    token_type: longBody.token_type ?? "bearer",
    expires_at: expiresAt,
    scope: REQUESTED_SCOPES,
  };
}

async function fetchMetaUser(token: string): Promise<{ id: string; name: string; email?: string }> {
  const res = await fetch(
    `${GRAPH}/me?fields=id,name,email&access_token=${encodeURIComponent(token)}`,
  );
  if (!res.ok) {
    throw new Error(`/me lookup ${res.status}: ${await res.text()}`);
  }
  return (await res.json()) as { id: string; name: string; email?: string };
}

interface UpsertConnectionInput {
  userId: string;
  accountId: string;
  accountName: string;
  accessToken: string;
  tokenType: string;
  expiresAt: number | null;
  scope: string | null;
  raw: unknown;
}

async function upsertConnection(
  env: Bindings,
  input: UpsertConnectionInput,
): Promise<{ id: string }> {
  const now = Date.now();
  const existing = await env.DB.prepare(
    "SELECT id FROM provider_connections WHERE user_id = ? AND provider = 'meta'",
  )
    .bind(input.userId)
    .first<{ id: string }>();

  if (existing) {
    await env.DB.prepare(
      `UPDATE provider_connections
          SET account_id = ?, account_name = ?, access_token = ?,
              scope = ?, token_type = ?, expires_at = ?, updated_at = ?, raw_json = ?
        WHERE id = ?`,
    )
      .bind(
        input.accountId,
        input.accountName,
        input.accessToken,
        input.scope,
        input.tokenType,
        input.expiresAt,
        now,
        JSON.stringify(input.raw),
        existing.id,
      )
      .run();
    return existing;
  }

  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO provider_connections
       (id, user_id, provider, account_id, account_name, access_token, scope, token_type,
        expires_at, connected_at, updated_at, raw_json)
     VALUES (?, ?, 'meta', ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      input.userId,
      input.accountId,
      input.accountName,
      input.accessToken,
      input.scope,
      input.tokenType,
      input.expiresAt,
      now,
      now,
      JSON.stringify(input.raw),
    )
    .run();
  return { id };
}

async function markSessionError(env: Bindings, sessionId: string, error: string): Promise<void> {
  await env.DB.prepare("UPDATE pending_oauth_sessions SET status = 'error', error = ? WHERE id = ?")
    .bind(error.slice(0, 500), sessionId)
    .run();
}

function successPage(name: string): string {
  return `<!doctype html><html><head><title>Connected</title>
<style>body{font:14px -apple-system,system-ui,sans-serif;max-width:480px;margin:80px auto;padding:24px;color:#222}</style>
</head><body>
<h1>✓ Connected as ${escapeHtml(name)}</h1>
<p>Your Meta account is now linked to brandnana. You can close this tab and return to the CLI.</p>
</body></html>`;
}

function errorPage(message: string): string {
  return `<!doctype html><html><head><title>OAuth error</title>
<style>body{font:14px -apple-system,system-ui,sans-serif;max-width:480px;margin:80px auto;padding:24px;color:#222}</style>
</head><body>
<h1>✗ Couldn't link your Meta account</h1>
<p>${escapeHtml(message)}</p>
<p>Re-run <code>brandnana auth meta</code> to retry.</p>
</body></html>`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export default meta;
