// POST /v1/creative/analyze — SERVER-SIDE vision analysis of one ad creative.
//
// WHY THIS EXISTS (the general pattern):
//   The brandnana agent runs inside the Workbooks engine, whose tool_registry
//   SCRUBS every secret-looking env var from the agent's bash before a command
//   runs (runtime/engine/lib/workbooks_runtime/tool_registry.ex @secret_substrings
//   includes "API_KEY"). So the agent's `brandnana ...` invocations NEVER see an
//   OPENROUTER_API_KEY — a CLI verb that reads a provider key from process.env is
//   structurally broken for the agent.
//
//   The fix (mirrors POST /v1/book/publish + /v1/book/render-slides): ANY
//   provider-keyed capability the agent needs becomes a CLI→server verb. The CLI
//   carries only the brandnana API-key bearer (which IS forwarded — see the
//   WB_FORWARD_SECRETS allowlist for BRANDNANA_API_KEY) and POSTs to THIS worker;
//   the worker holds the provider key in a Cloudflare secret binding and makes
//   the upstream call. The agent needs NO provider keys. This is the template for
//   every future provider-keyed agent tool.
//
// Auth: existing bearer (same posture as /v1/book — requireBearer below).
//
// Request body (application/json):
//   { url: string, kind: "image" | "video", brand?: string,
//     poster?: string, context?: string }
//
// Response on success:
//   { ok: true, url, kind, model, analysis }
//   where `analysis` is the structured CreativeAnalysis the CLI prints (the
//   ad-vision skill captures `analysis.summary` into analysis/ad-vision/*.org).
//
// The OpenRouter vision call is performed SERVER-SIDE with the worker's
// OPENROUTER_API_KEY binding (env.OPENROUTER_API_KEY) — the key is NEVER read
// from the request. The rich routing logic (image / carousel / video with a
// poster-frame fallback, minimax/minimax-m3) lives in ./vision.ts, lifted from
// apps/cli/src/commands/creative-vision.ts so the two stay in lockstep.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { type Creative, analyzeCreative } from "./vision.js";

const creative = new Hono<{ Bindings: Bindings }>();
creative.use("*", requireBearer);

const MAX_URL_LEN = 4096;

/** Accept only http(s) URLs of a sane length — never a data: / file: / blob:
 *  URL (SSRF surface) and never something pathologically long. */
function validUrl(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > MAX_URL_LEN) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  return raw;
}

creative.post("/analyze", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    url?: string;
    kind?: string;
    brand?: string;
    poster?: string;
    context?: string;
  };

  const url = validUrl(body.url);
  if (!url) {
    return c.json(
      { error: "invalid_url", message: "url is required and must be an absolute http(s) URL" },
      400,
    );
  }

  const kind = body.kind === "video" ? "video" : body.kind === "image" ? "image" : null;
  if (!kind) {
    return c.json(
      { error: "invalid_kind", message: 'kind is required and must be "image" or "video"' },
      400,
    );
  }

  const poster = body.poster !== undefined ? validUrl(body.poster) : null;
  if (body.poster !== undefined && body.poster !== "" && !poster) {
    return c.json(
      { error: "invalid_poster", message: "poster, when given, must be an absolute http(s) URL" },
      400,
    );
  }

  // The provider key comes from the worker's binding — NEVER the request.
  // A missing key is an operator/config fault (4xx with actionable text), not a
  // blind 500: surface exactly what's wrong so it can be fixed via wrangler.
  const openrouterKey = c.env.OPENROUTER_API_KEY;
  if (!openrouterKey) {
    return c.json(
      {
        error: "provider_unconfigured",
        message:
          "OPENROUTER_API_KEY is not set on the worker. Set it via `wrangler secret put OPENROUTER_API_KEY`.",
      },
      503,
    );
  }

  const creativeInput: Creative = {
    kind,
    url,
    poster_url: poster ?? undefined,
    context: typeof body.context === "string" ? body.context : undefined,
  };

  let analysis: Awaited<ReturnType<typeof analyzeCreative>>;
  try {
    analysis = await analyzeCreative(creativeInput, { openrouter: openrouterKey }, fetch);
  } catch (e) {
    // analyzeCreative is fail-soft (it returns an analysis with an `error`
    // field rather than throwing on upstream failures), so a throw here is an
    // unexpected fault — surface it as a 502 (upstream/vendor), never a blind 500.
    return c.json({ error: "vision_failed", message: (e as Error).message }, 502);
  }

  return c.json({
    ok: true,
    url,
    kind,
    model: analysis.via,
    analysis,
  });
});

export default creative;
