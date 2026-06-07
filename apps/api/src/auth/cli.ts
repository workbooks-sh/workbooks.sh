// CLI sign-in via GitHub OAuth device flow.
//
// Flow:
//   1. CLI fetches /auth/cli/config to learn the GH client_id.
//   2. CLI calls GitHub's device-code endpoint directly, polls until the
//      user finishes the browser step, gets a GitHub access_token.
//   3. CLI POSTs that token to /auth/cli/exchange. We validate it with
//      api.github.com/user, upsert into `users`, mint a fresh API key,
//      and return the cleartext exactly once.
//
// No GitHub OAuth App client_secret is required — device flow is
// designed for public clients (CLIs, native apps).

import { Hono } from "hono";
import type { Bindings } from "../env.js";
import { mintKey } from "./keys.js";

const cli = new Hono<{ Bindings: Bindings }>();

cli.get("/config", (c) => {
  const clientId = c.env.GITHUB_CLIENT_ID;
  if (!clientId) {
    return c.json(
      {
        error: "not_configured",
        message:
          "GITHUB_CLIENT_ID is not set on the worker. " +
          "Create a GitHub OAuth App (https://github.com/settings/developers) " +
          "with Device Flow enabled, then push the client id via " +
          "apps/api/scripts/secrets-push.sh.",
      },
      503,
    );
  }
  return c.json({
    provider: "github",
    github_client_id: clientId,
    device_endpoint: "https://github.com/login/device/code",
    token_endpoint: "https://github.com/login/oauth/access_token",
    scopes: "read:user user:email",
  });
});

interface ExchangeBody {
  github_token?: string;
  label?: string;
}

interface GitHubUser {
  id: number;
  login: string;
  name?: string | null;
  email?: string | null;
  avatar_url?: string | null;
}

cli.post("/exchange", async (c) => {
  let body: ExchangeBody;
  try {
    body = (await c.req.json()) as ExchangeBody;
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const token = body.github_token?.trim();
  if (!token) {
    return c.json({ error: "missing_github_token" }, 400);
  }

  const ghRes = await fetch("https://api.github.com/user", {
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "user-agent": "brandnana-api",
      "x-github-api-version": "2022-11-28",
    },
  });
  if (!ghRes.ok) {
    return c.json({ error: "github_validation_failed", status: ghRes.status }, 401);
  }
  const gh = (await ghRes.json()) as GitHubUser;
  if (typeof gh.id !== "number" || typeof gh.login !== "string") {
    return c.json({ error: "github_response_invalid" }, 502);
  }

  // Best-effort email lookup (the /user endpoint may not return it).
  let email: string | null = gh.email ?? null;
  if (!email) {
    const emailsRes = await fetch("https://api.github.com/user/emails", {
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "user-agent": "brandnana-api",
      },
    });
    if (emailsRes.ok) {
      const emails = (await emailsRes.json()) as Array<{
        email: string;
        primary: boolean;
        verified: boolean;
      }>;
      const primary = emails.find((e) => e.primary && e.verified);
      email = primary?.email ?? null;
    }
  }

  const now = Date.now();
  const existing = await c.env.DB.prepare("SELECT id FROM users WHERE github_id = ?")
    .bind(gh.id)
    .first<{ id: string }>();

  let userId: string;
  if (existing) {
    userId = existing.id;
    await c.env.DB.prepare(
      `UPDATE users
          SET github_login = ?, email = ?, name = ?, avatar_url = ?, updated_at = ?
        WHERE id = ?`,
    )
      .bind(gh.login, email, gh.name ?? null, gh.avatar_url ?? null, now, userId)
      .run();
  } else {
    userId = crypto.randomUUID();
    await c.env.DB.prepare(
      `INSERT INTO users (id, github_id, github_login, email, name, avatar_url, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(userId, gh.id, gh.login, email, gh.name ?? null, gh.avatar_url ?? null, now, now)
      .run();
  }

  const { cleartext, hash, prefix } = await mintKey();
  const keyId = crypto.randomUUID();
  await c.env.DB.prepare(
    `INSERT INTO api_keys (id, user_id, hash, prefix, label, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(keyId, userId, hash, prefix, body.label ?? `cli@${gh.login}`, now)
    .run();

  return c.json({
    api_key: cleartext,
    prefix,
    user: { id: userId, github_login: gh.login, email },
  });
});

export default cli;
