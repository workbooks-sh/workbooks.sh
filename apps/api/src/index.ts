import type { EventInsert } from "@brandnana/schema/events";
import { VERBS } from "@brandnana/schema/verbs";
import { Hono } from "hono";
import { cors } from "hono/cors";
import ads from "./ads/routes.js";
import agentRoutes from "./agent/routes.js";
import aiSmoke from "./ai-smoke/routes.js";
import cliFlow from "./auth/cli-flow.js";
import cliAuth from "./auth/cli.js";
import { requireBearer } from "./auth/middleware.js";
import portalAuth from "./auth/portal-keys.js";
import book from "./book/routes.js";
import bookServe, { conceptImages } from "./book/serve.js";
import brand from "./brand/routes.js";
import brief from "./brief/routes.js";
import { CrawlCoordinator } from "./catalog/coordinator.js";
import catalog from "./catalog/routes.js";
import creative from "./creative/routes.js";
import design from "./design/routes.js";
import type { Bindings } from "./env.js";
import { recordEvent } from "./events.js";
import mirror from "./mirror/routes.js";
import metaOAuth from "./oauth/meta.js";
import { priceAndUpdateEvent } from "./profit.js";
import resolve from "./resolve/routes.js";
import scrape from "./scrape/routes.js";
import skillsRoutes from "./skills/routes.js";
import social from "./social/routes.js";
import usage from "./usage/routes.js";

const app = new Hono<{ Bindings: Bindings }>();

// CORS — allow brandnana portal hosts + localhost dev.
// The portal at app.brandnana.net needs to POST to /v1/auth/portal/* with the
// Clerk session JWT, GET /v1/auth/portal/keys, DELETE keys, etc.
app.use(
  "*",
  cors({
    origin: (origin) => {
      if (!origin) return undefined; // non-browser requests (curl, CLI) pass through
      const ok =
        origin === "https://app.brandnana.net" ||
        origin === "https://brandnana.net" ||
        origin === "https://www.brandnana.net" ||
        /^https:\/\/[a-z0-9-]+\.brandnana-portal\.pages\.dev$/.test(origin) ||
        /^http:\/\/localhost(:\d+)?$/.test(origin) ||
        /^http:\/\/127\.0\.0\.1(:\d+)?$/.test(origin);
      return ok ? origin : undefined;
    },
    allowMethods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization", "X-Clerk-Session-Jwt", "X-Brandnana-Source"],
    exposeHeaders: [
      "X-Brandnana-Book-Slug",
      "X-Brandnana-Book-Cached",
      "X-Brandnana-Book-Cost-Usd",
    ],
    credentials: false,
    maxAge: 86400,
  }),
);

// Post-response event log middleware.
// Fires after every route, records one row in the events table.
// account_id comes from c.get('user') set by requireBearer; falls back to
// 'anonymous' for public routes (health, auth, /). vendor_cost_usd + vendor_calls
// are placeholders until wb-ew65.3 / wb-ew65.5 wire them in.
app.use("*", async (c, next) => {
  const start = Date.now();
  await next();
  // Best-effort: never let event recording break the response.
  c.executionCtx.waitUntil(
    (async () => {
      try {
        const user = c.get("user" as never) as { id?: string } | undefined;
        const account_id = user?.id ?? "anonymous";
        const method = c.req.method;
        const path = new URL(c.req.url).pathname;
        // Map path+method to a verb_id. Best-effort: prefix-match VERBS catalog.
        const verb = VERBS.find(
          (v) =>
            v.httpPath &&
            path.startsWith(v.httpPath.replace(/:\w+/g, "")) &&
            v.httpMethod === method,
        );
        const verb_id = verb?.id ?? `${method.toLowerCase()}:${path}`;
        const status = c.res.status >= 400 ? "error" : "ok";
        const error_code = status === "error" ? String(c.res.status) : undefined;
        const rawSource = c.req.header("x-brandnana-source") ?? "api";
        const validSources = ["cli", "mcp", "portal", "api", "agent", "simulation"] as const;
        const source = (validSources as readonly string[]).includes(rawSource)
          ? (rawSource as EventInsert["source"])
          : "api";

        const event_id = crypto.randomUUID();
        const event_ts = Date.now();

        await recordEvent(c.env.DB, {
          id: event_id,
          ts: event_ts,
          account_id,
          verb_id,
          source,
          duration_ms: Date.now() - start,
          status,
          error_code,
          vendor_cost_usd: 0,
          vendor_calls: null,
        });

        // Margin pass: pin customer_rate_card_id even when vendor_calls is
        // empty (markup × 0 = 0, but the card is recorded for billing audit).
        // Real vendor calls will be collected and passed here once gateway
        // modules emit them into a per-request collector (follow-up task).
        await priceAndUpdateEvent(c.env.DB, event_id, [], verb_id, event_ts);
      } catch {
        // swallow — never break the response for telemetry
      }
    })(),
  );
});

app.get("/", (c) =>
  c.json({
    service: "brandnana-api",
    status: "ok",
    docs: "https://github.com/shinyobjectz/brandnana",
  }),
);

app.get("/health", async (c) => {
  const env = c.env;
  const bindings: Record<string, "ok" | "missing" | "error"> = {};

  bindings.DB = await probeD1(env.DB);
  bindings.ASSETS = await probeR2(env.ASSETS);
  bindings.BROWSER = env.BROWSER ? "ok" : "missing";

  const secretKeys = [
    "CEREBRAS_API_KEY",
    "OPENROUTER_API_KEY",
    "CLERK_SECRET_KEY",
    "FIRECRAWL_API_KEY",
    "SCRAPECREATORS_API_KEY",
    "CONTEXT_DEV_API_KEY",
    "VALYU_API_KEY",
    "WORKOS_API_KEY",
    "WORKOS_CLIENT_ID",
    "GROQ_API_KEY",
    "THE_COMPANIES_API_KEY",
  ] as const;
  const secrets: Record<string, "set" | "missing"> = {};
  for (const k of secretKeys) {
    secrets[k] = env[k] ? "set" : "missing";
  }

  return c.json({
    service: "brandnana-api",
    status: "ok",
    env: env.ENV_NAME ?? "unknown",
    bindings,
    secrets,
  });
});

app.route("/auth/cli", cliAuth);
app.route("/auth/meta", metaOAuth);
app.route("/scrape", scrape);
app.route("/v1/resolve", resolve);
app.route("/v1/book", book);
// SERVER-MANAGED creative vision — the agent's `brandnana creative analyze`
// POSTs here; the worker holds the OpenRouter key (env.OPENROUTER_API_KEY) and
// runs the vision call, so the agent never needs a provider key. See
// ./creative/routes.ts for the general CLI→server pattern this establishes.
app.route("/v1/creative", creative);
app.route("/ads", ads);
app.route("/brand", brand);
app.route("/catalog", catalog);
app.route("/design", design);
app.route("/usage", usage);
app.route("/social", social);
app.route("/brief", brief);
app.route("/v1/_smoke/ai", aiSmoke); // dev: verify Cerebras path is wired
app.route("/v1/agent", agentRoutes); // free-form query → plan → execute → answer
app.route("/v1/auth/portal", portalAuth); // Clerk JWT → API key minting (for portal)
app.route("/v1/auth/cli", cliFlow); // Clerk-based device flow for `brandnana login`
app.route("/v1/skills", skillsRoutes); // downloadable skill bundles (public)
app.route("/books", bookServe); // public + private brand-book serving
app.route("/concept-images", conceptImages); // images for concept decks (public, cache forever)
app.route("/", mirror); // mounts /assets/:filename + /mirror/images

app.get("/whoami", requireBearer, (c) => c.json({ user: c.get("user") }));

// Sanity-check: every VERB entry with a non-empty httpPath that has an HTTP
// surface should map to at least one registered Hono route. We assert at
// module load so a missing route is a startup error, not a silent 404.
// Only checks verbs that have a real httpPath (audit-trace is CLI-only).
const registeredPaths = new Set(app.routes.map((r: { path: string }) => r.path));

const ROUTE_PREFIX_MAP: Record<string, string> = {
  "/auth/cli": "/auth/cli",
  "/auth/meta": "/auth/meta",
  "/ads": "/ads",
  "/brand": "/brand",
  "/brief": "/brief",
  "/catalog": "/catalog",
  "/design": "/design",
  "/social": "/social",
  "/usage": "/usage",
  "/v1/resolve": "/v1/resolve",
  "/v1/book": "/v1/book",
  "/whoami": "/whoami",
  "/health": "/health",
};

for (const verb of VERBS) {
  if (!verb.httpPath) continue; // CLI-only verbs (audit-trace) have no httpPath
  const prefix = Object.keys(ROUTE_PREFIX_MAP).find((p) => verb.httpPath.startsWith(p));
  if (!prefix) continue; // top-level path, skip (e.g. "/" health check)
  // Verify that at least one Hono route covers the prefix. This catches
  // catalog entries for route groups that were never mounted.
  const covered = app.routes.some((r: { path: string }) => r.path.startsWith(prefix));
  if (!covered) {
    throw new Error(
      `[brandnana/schema] verb "${verb.id}" references path "${verb.httpPath}" but no Hono route covers prefix "${prefix}". Mount the route or update the verb catalog.`,
    );
  }
  void registeredPaths; // used implicitly via app.routes above
}

async function probeD1(db: D1Database | undefined): Promise<"ok" | "missing" | "error"> {
  if (!db) return "missing";
  try {
    await db.prepare("SELECT 1").first();
    return "ok";
  } catch {
    return "error";
  }
}

async function probeR2(bucket: R2Bucket | undefined): Promise<"ok" | "missing" | "error"> {
  if (!bucket) return "missing";
  try {
    await bucket.list({ limit: 1 });
    return "ok";
  } catch {
    return "error";
  }
}

// Coming next:
// app.route("/brand", brandRoutes);
// app.route("/catalog", catalogRoutes);
// app.route("/ads", adsRoutes);

// DO export — wrangler binds the class by name. See wrangler.toml.
export { CrawlCoordinator };

export default app;
