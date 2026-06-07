import { createMiddleware } from "hono/factory";
import type { Bindings } from "../env.js";
import { extractBearer, sha256Hex } from "./keys.js";

const RATE_WINDOW_MS = 60_000;

export interface AuthedUser {
  id: string;
  github_login: string | null;
  email: string | null;
  apiKeyId: string;
  rateLimitPerMin: number;
}

declare module "hono" {
  interface ContextVariableMap {
    user: AuthedUser;
  }
}

export const requireBearer = createMiddleware<{
  Bindings: Bindings;
  Variables: { user: AuthedUser };
}>(async (c, next) => {
  const raw = extractBearer(c.req.header("authorization"));
  if (!raw) {
    return c.json({ error: "missing_bearer", message: "Bearer token required" }, 401);
  }
  const hash = await sha256Hex(raw);
  const row = await c.env.DB.prepare(
    `SELECT k.id AS api_key_id, k.user_id, k.revoked_at, k.rate_limit_per_min,
            u.github_login, u.email
       FROM api_keys k
       JOIN users u ON u.id = k.user_id
      WHERE k.hash = ?`,
  )
    .bind(hash)
    .first<{
      api_key_id: string;
      user_id: string;
      revoked_at: number | null;
      rate_limit_per_min: number;
      github_login: string | null;
      email: string | null;
    }>();

  if (!row) {
    return c.json({ error: "invalid_token", message: "API key not recognised" }, 401);
  }
  if (row.revoked_at) {
    return c.json({ error: "revoked_token", message: "API key has been revoked" }, 401);
  }

  // Per-key rate limit (sliding 60s window). Counts every request that
  // makes it past the bearer check.
  const limit = row.rate_limit_per_min ?? 600;
  const windowStart = Math.floor(Date.now() / RATE_WINDOW_MS) * RATE_WINDOW_MS;
  const counter = await c.env.DB.prepare(
    `INSERT INTO api_key_rate_limit (api_key_id, window_start, count)
     VALUES (?, ?, 1)
     ON CONFLICT(api_key_id, window_start) DO UPDATE SET count = count + 1
     RETURNING count`,
  )
    .bind(row.api_key_id, windowStart)
    .first<{ count: number }>();
  if (counter && counter.count > limit) {
    c.header("retry-after", "60");
    return c.json(
      { error: "rate_limited", message: `API key exceeded ${limit}/min`, limit, retry_after: 60 },
      429,
    );
  }

  // Best-effort: record last-used. Don't block the request on this.
  c.executionCtx.waitUntil(
    c.env.DB.prepare("UPDATE api_keys SET last_used_at = ? WHERE id = ?")
      .bind(Date.now(), row.api_key_id)
      .run()
      .catch(() => undefined),
  );

  c.set("user", {
    id: row.user_id,
    github_login: row.github_login,
    email: row.email,
    apiKeyId: row.api_key_id,
    rateLimitPerMin: limit,
  });
  await next();
});
