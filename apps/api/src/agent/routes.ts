// POST /v1/agent — plan synchronously, execute async in waitUntil.
//
// Body: { query: string, plan_only?: boolean }
// Returns immediately with { slug, plan, workbook_url } — caller polls
// the workbook URL until it returns 200 (R2 stores progressive HTML).
//
// Auth: bearer (same as the rest of /v1).

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { planRequest, planAsOrg } from "./planner.js";
import { executePlan } from "./executor.js";

const app = new Hono<{ Bindings: Bindings }>();
app.use("*", requireBearer);

// In-flight job state, keyed by slug. R2 is the durable store; this is just
// in-memory for the same isolate so quick double-polls don't double-execute.
const inflight = new Set<string>();

app.post("/", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { query?: string; plan_only?: boolean };
  const query = body.query?.trim() ?? "";
  if (!query) return c.json({ error: "missing_query" }, 400);
  if (query.length > 4000) return c.json({ error: "query_too_long", limit: 4000 }, 413);

  // Phase 1 (sync): plan. Bounded ~2s with deepseek-v4-flash.
  let plan, planMeta;
  try {
    const planned = await planRequest(
      { openrouter: c.env.OPENROUTER_API_KEY, cerebras: c.env.CEREBRAS_API_KEY },
      query,
    );
    plan = planned.plan;
    planMeta = { latency_ms: planned.latency_ms, cost_usd: planned.cost_usd, model: planned.model };
  } catch (e) {
    return c.json({ error: "plan_failed", message: (e as Error).message }, 502);
  }

  if (body.plan_only) {
    return c.json({
      query,
      plan,
      plan_org: planAsOrg(plan),
      plan_meta: planMeta,
      executed: false,
    });
  }

  // Pre-compute slug so the response URL is correct before execution finishes.
  const slug = `${(plan.domains[0] ?? "wb").replace(/\./g, "-")}-${plan.format}-${Date.now().toString(36)}`;
  const workbook_url = `https://api.brandnana.net/books/${slug}.html`;
  const status_url = `https://api.brandnana.net/v1/agent/job/${slug}`;

  // Phase 2 (async): execute. Survives the response cycle via waitUntil.
  if (!inflight.has(slug)) {
    inflight.add(slug);
    c.executionCtx.waitUntil(
      executePlan(c.env, plan, query, { presetSlug: slug })
        .then(async (result) => {
          // Drop a status manifest next to the workbook so /job/:slug can read it.
          try {
            await c.env.ASSETS.put(`agent-jobs/${slug}/status.json`, JSON.stringify({
              status: "done",
              workbook_url: result.workbook_url,
              workbook_bytes: result.workbook_bytes,
              total_cost_usd: result.total_cost_usd,
              total_latency_ms: result.total_latency_ms,
              images: result.images.length,
              timeline: result.timeline,
              finished_at: new Date().toISOString(),
            }), { httpMetadata: { contentType: "application/json" } });
          } catch { /* non-fatal */ }
          inflight.delete(slug);
        })
        .catch(async (err) => {
          try {
            await c.env.ASSETS.put(`agent-jobs/${slug}/status.json`, JSON.stringify({
              status: "failed",
              error: (err as Error).message,
              finished_at: new Date().toISOString(),
            }), { httpMetadata: { contentType: "application/json" } });
          } catch { /* non-fatal */ }
          inflight.delete(slug);
        }),
    );
  }

  return c.json({
    query,
    plan,
    plan_org: planAsOrg(plan),
    plan_meta: planMeta,
    executed: false, // async — poll the URLs below
    slug,
    workbook_url,
    status_url,
    note: "Workbook URL returns 200 once execution completes (~30-90s for most queries). Poll status_url for progress.",
  });
});

// GET /v1/agent/job/:slug — status manifest written by the async executor.
app.get("/job/:slug", async (c) => {
  const slug = c.req.param("slug");
  if (!/^[a-z0-9_-]+$/i.test(slug)) return c.json({ error: "invalid_slug" }, 400);
  const obj = await c.env.ASSETS.get(`agent-jobs/${slug}/status.json`);
  if (!obj) {
    return c.json({
      slug,
      status: inflight.has(slug) ? "running" : "unknown",
      note: inflight.has(slug)
        ? "Execution in progress on this isolate."
        : "No status manifest yet — either still queueing or job is on a different isolate.",
    });
  }
  const text = await obj.text();
  try {
    return c.json({ slug, ...JSON.parse(text) });
  } catch {
    return c.json({ slug, status: "unreadable" }, 502);
  }
});

export default app;
