// Per-tenant usage rollup. Reads from D1 vendor_calls (populated by
// vendor.ts on every non-LLM upstream call) and api_key_rate_limit.
// Per-provider cost numbers come from a fixed table for now since AI
// Gateway's per-call cost API isn't wired here yet; the duration_ms
// and call counts give a reasonable proxy.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";

const usage = new Hono<{ Bindings: Bindings }>();
usage.use("*", requireBearer);

// Indicative $/1000-call estimates, used until AI Gateway cost API is
// wired. Update as we get real billing numbers from each vendor.
const COST_PER_1K_CALLS: Record<string, number> = {
  exa: 5.0,
  firecrawl: 2.0,
  "context-dev": 1.0,
  "scrapecreators-meta": 3.0,
  "scrapecreators-tiktok": 3.0,
  "scrapecreators-google": 3.0,
};

interface ProviderRollup {
  provider: string;
  calls: number;
  cache_hits: number;
  cache_misses: number;
  bytes: number;
  duration_ms_total: number;
  duration_ms_avg: number;
  estimated_cost_usd: number;
}

usage.get("/", async (c) => {
  const user = c.get("user");
  const sinceParam = c.req.query("since_hours");
  const sinceHours = Math.min(Math.max(Number(sinceParam ?? 24), 1), 24 * 90);
  const sinceMs = Date.now() - sinceHours * 60 * 60 * 1000;

  const rows = await c.env.DB.prepare(
    `SELECT provider,
            COUNT(*) AS calls,
            SUM(CASE WHEN cache_state = 'hit' THEN 1 ELSE 0 END) AS cache_hits,
            SUM(CASE WHEN cache_state = 'miss' THEN 1 ELSE 0 END) AS cache_misses,
            COALESCE(SUM(bytes), 0) AS bytes,
            COALESCE(SUM(duration_ms), 0) AS duration_ms_total
       FROM vendor_calls
      WHERE tenant = ? AND called_at >= ?
      GROUP BY provider
      ORDER BY calls DESC`,
  )
    .bind(user.id, sinceMs)
    .all<{
      provider: string;
      calls: number;
      cache_hits: number;
      cache_misses: number;
      bytes: number;
      duration_ms_total: number;
    }>();

  const providers: ProviderRollup[] = (rows.results ?? []).map((r) => {
    const upstreamCalls = r.calls - r.cache_hits;
    const cost = ((COST_PER_1K_CALLS[r.provider] ?? 0) * upstreamCalls) / 1000;
    return {
      provider: r.provider,
      calls: r.calls,
      cache_hits: r.cache_hits,
      cache_misses: r.cache_misses,
      bytes: r.bytes,
      duration_ms_total: r.duration_ms_total,
      duration_ms_avg: r.calls > 0 ? Math.round(r.duration_ms_total / r.calls) : 0,
      estimated_cost_usd: Math.round(cost * 100) / 100,
    };
  });

  const totals = providers.reduce(
    (acc, p) => ({
      calls: acc.calls + p.calls,
      cache_hits: acc.cache_hits + p.cache_hits,
      bytes: acc.bytes + p.bytes,
      estimated_cost_usd: acc.estimated_cost_usd + p.estimated_cost_usd,
    }),
    { calls: 0, cache_hits: 0, bytes: 0, estimated_cost_usd: 0 },
  );

  // Current minute's API request count for the active key.
  const windowStart = Math.floor(Date.now() / 60_000) * 60_000;
  const apiWindow = await c.env.DB.prepare(
    "SELECT count FROM api_key_rate_limit WHERE api_key_id = ? AND window_start = ?",
  )
    .bind(user.apiKeyId, windowStart)
    .first<{ count: number }>();

  return c.json({
    tenant: user.id,
    since_hours: sinceHours,
    api_key: {
      id: user.apiKeyId,
      rate_limit_per_min: user.rateLimitPerMin,
      current_window_count: apiWindow?.count ?? 0,
    },
    providers,
    totals: {
      ...totals,
      estimated_cost_usd: Math.round(totals.estimated_cost_usd * 100) / 100,
      cache_hit_rate: totals.calls > 0 ? Math.round((totals.cache_hits / totals.calls) * 100) : 0,
    },
  });
});

export default usage;
