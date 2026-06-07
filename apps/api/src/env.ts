export type Bindings = {
  ENV_NAME: string;
  DB: D1Database;
  ASSETS: R2Bucket;
  BROWSER: Fetcher;
  /** Per-(tenant, domain) crawl coordinator — see ./catalog/coordinator.ts.
   * Optional so local/dev deploys without the DO binding still typecheck. */
  CRAWL?: DurableObjectNamespace;
  // CF account id + AI Gateway id (used to construct gateway URLs in
  // llm/openrouter.ts). DEAD in prod — no CF AI Gateway token is set, so
  // calls go direct. Kept optional for back-compat / future re-enable.
  CF_ACCOUNT_ID?: string;
  AI_GATEWAY_ID?: string;
  // Bearer token for the AI Gateway (cf-aig-authorization). DEAD — not set
  // in prod; llm/openrouter.ts falls back to calling OpenRouter directly.
  CF_AI_GATEWAY_TOKEN?: string;
  // OAuth client id for GitHub device-flow sign-in. Public string (no
  // secret needed for device flow). Push via secrets-push.sh or set as
  // a [vars] entry once chosen.
  GITHUB_CLIENT_ID?: string;
  // Vendor + OAuth secrets (populated via wrangler secret bulk)
  // "brandnana" Meta App (id 1600801264319182). META_CLIENT_ID is the
  // app id; META_CLIENT_SECRET is needed to mint per-user OAuth tokens
  // (apps/api/src/oauth/meta.ts). META_GRAPH_TOKEN is a dev-only
  // global user token for the worker owner — replace with per-user
  // tokens minted via the OAuth flow once that's wired.
  META_APP_ID?: string;
  META_CLIENT_ID?: string;
  META_CLIENT_SECRET?: string;
  META_GRAPH_TOKEN?: string;
  TIKTOK_CLIENT_ID?: string;
  TIKTOK_CLIENT_SECRET?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  /** DEPRECATED — replaced by Valyu, remove after migration. */
  EXA_API_KEY?: string;
  FIRECRAWL_API_KEY?: string;
  SCRAPECREATORS_API_KEY?: string;
  /** context.dev (rebrand of logo.dev). Covers brand retrieve, styleguide,
   *  fonts, web scraping, product extraction, NAICS/SIC lookup. */
  CONTEXT_DEV_API_KEY?: string;
  /** Valyu Search API — general WEB RESEARCH (domain resolution,
   *  competitor/brand discovery, /scrape web search, book research legs).
   *  POST https://api.valyu.ai/v1/search, header x-api-key. Replaces Exa. */
  VALYU_API_KEY?: string;
  /** OpenRouter — unified API to every LLM provider. PRIMARY book-composition
   *  LLM (and the vision verifier in agent/vision-verify.ts). */
  OPENROUTER_API_KEY?: string;
  /** Cerebras — primary AI provider for brandnana agent curation. Default
   *  model: zai-glm-4.7. Direct (no AI Gateway proxy in v1). See ./ai.ts. */
  CEREBRAS_API_KEY?: string;
  /** Clerk secret key — used by /v1/auth/portal/* to verify session JWTs
   *  minted by the portal and bridge them to brandnana API keys. */
  CLERK_SECRET_KEY?: string;
  /** WorkOS — AuthKit/SSO. API key + client id. */
  WORKOS_API_KEY?: string;
  WORKOS_CLIENT_ID?: string;
  /** Groq — fast inference provider (alternative LLM upstream). */
  GROQ_API_KEY?: string;
  /** The Companies API (thecompaniesapi.com) — company enrichment behind
   *  GET /brand/:domain/company. */
  THE_COMPANIES_API_KEY?: string;
  /** Cost-margin multiplier — see apps/api/src/pricing.ts. Defaults to 1.5x, clamped to [1.0, 3.0]. */
  BRANDNANA_COST_MARGIN?: string;
  /** Canonical public base for mirrored R2 assets (e.g. https://api.brandnana.net).
   *  When unset, mirror/routes.ts falls back to the hardcoded canonical host so
   *  every /assets/<sha> URL is stable regardless of which worker host served
   *  the request. NEVER derive this from the request URL — that leaks the
   *  *.workers.dev default host into the substrate. */
  MIRROR_ASSET_BASE?: string;
  /** Workbooks Engine TenantToken signing key (HMAC-SHA256). The worker mints a
   *  short-lived per-tenant TenantToken with this key when it calls the engine
   *  (loopback) under WB_TENANCY_MODE=multi; the engine verifies the HMAC and
   *  derives the tenant from the signed payload (forgery-proof). See
   *  engine-client.ts (mintTenantToken / engineBearerHeader) and the Elixir
   *  verifier runtime/engine/.../api/tenant_token.ex.
   *
   *  MUST be provisioned into the worker's Cloudflare secrets as the SAME value
   *  that is live on bn-engine (deploy-kit common.sh:60 mints it for the engine):
   *    wrangler secret put WB_TENANT_TOKEN_KEY   (or via scripts/secrets-push.sh)
   *  A token signed with any other value is rejected by the engine (test T9).
   *  >= 16 bytes (tenant_token.ex:79). Optional in the type only so single-mode/
   *  dev deploys that never call the engine still typecheck. */
  WB_TENANT_TOKEN_KEY?: string;
};
