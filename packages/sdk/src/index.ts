import type {
  Ad,
  AdSource,
  Brand,
  Product,
  ProductImage,
  ProductPlatform,
} from "@brandnana/schema";

export interface BrandnanaClientOptions {
  /** Base URL of the Brandnana API. Defaults to https://api.brandnana.net */
  baseUrl?: string;
  /** Bearer token. Required for every call except /health. */
  apiKey: string;
  /** Override fetch (testing, polyfills). Defaults to globalThis.fetch. */
  fetch?: typeof globalThis.fetch;
  /**
   * Total deadline (ms) for a non-streaming `call()`. Keep BELOW the engine's
   * agent-bash timeout so a hung upstream surfaces as a loud BrandnanaError
   * (exit 1) instead of being silently truncated by bash. Default 120000.
   */
  callTimeoutMs?: number;
  /**
   * IDLE deadline (ms) for `stream()` — abort if NO chunk arrives for this long.
   * NOT a total cap: a healthy catalog crawl legitimately streams for minutes,
   * so we watch for a HUNG stream, not a slow one. Default 90000.
   */
  streamIdleMs?: number;
}

const DEFAULT_BASE_URL = "https://api.brandnana.net";

export type CatalogStrategy = "auto" | "shopify" | "context-dev" | "sitemap" | "llm";

export interface CatalogCrawlRequest {
  domain: string;
  strategy?: CatalogStrategy;
  brandId: string;
  maxUrls?: number;
}

/** Crawl state from GET /catalog/status/:domain (the crawl DO). */
export interface CatalogCrawlStatus {
  status: "idle" | "running" | "finished" | "failed" | string;
  crawl_id?: string;
  strategy?: string;
  started_at?: number;
  last_heartbeat_at?: number;
  finished_at?: number | null;
  products?: number;
  images?: number;
  pages_fetched?: number;
  errors?: unknown[];
}

export interface CrawlStatsRow {
  __type: "stats";
  products: number;
  images: number;
  pages_fetched?: number;
  urls_considered?: number;
  urls_fetched?: number;
  extraction_failures?: number;
  errors: string[];
  started_at: number;
  finished_at: number;
}

export interface ProductRow extends Product {
  __type: "product";
}

export interface ProductImageRow extends ProductImage {
  __type: "product_image";
}

export type CatalogRow = ProductRow | ProductImageRow | CrawlStatsRow;

export interface AdsSearchRequest {
  query: string;
  source?: AdSource | "all" | "exa";
  limit?: number;
  /** Optional brand domain or name for ad-library scoped searches. */
  brand?: string;
}

export interface AdsSyncRequest {
  source: AdSource | "all";
  brand?: string;
}

export interface AdsSyncResult {
  jobId: string;
  source: AdSource | "all";
  brand?: string;
}

export interface AuthProvider {
  provider: AdSource;
}

export interface AuthStartResult {
  auth_url: string;
  session_id: string;
  expires_at?: number;
  scopes?: string;
}

export interface AuthStatus {
  session_id: string;
  provider: AdSource;
  state: "pending" | "connected" | "error";
  error?: string | null;
  expires_at?: number;
}

export interface AuthConnection {
  provider: AdSource;
  account: string;
  connectedAt: number;
}

export interface MirrorResult {
  mapping: Record<string, string>;
  skipped: string[];
  bytes_stored: number;
}

export interface UsageProviderRollup {
  provider: string;
  calls: number;
  cache_hits: number;
  cache_misses: number;
  bytes: number;
  duration_ms_total: number;
  duration_ms_avg: number;
  estimated_cost_usd: number;
}

export interface UsageReport {
  tenant: string;
  since_hours: number;
  api_key: {
    id: string;
    rate_limit_per_min: number;
    current_window_count: number;
  };
  providers: UsageProviderRollup[];
  totals: {
    calls: number;
    cache_hits: number;
    bytes: number;
    estimated_cost_usd: number;
    cache_hit_rate: number;
  };
}

export interface HealthStatus {
  service: string;
  status: string;
  bindings?: Record<string, "ok" | "missing" | "error">;
}

/**
 * Typed font for the director to render scenes against. `css_url`
 * (when present) is the `@font-face` CDN URL — drop it into a
 * `<link rel="stylesheet">` and use `family` in your CSS.
 */
export interface BrandFont {
  name: string;
  family: string;
  fallbacks: string[];
  css_url: string | null;
  usage: {
    percent_elements: number | null;
    percent_words: number | null;
  };
  /** Integer weight stops found in @font-face declarations (400, 600, 700, ...). */
  weights?: number[];
  italic_supported?: boolean | null;
  /** Where the font ultimately comes from. */
  source?:
    | "google-fonts"
    | "fontshare"
    | "bunny-fonts"
    | "adobe-fonts"
    | "brand-cdn"
    | "self-hosted"
    | "system"
    | "unknown";
  /** Direct font-file URLs (.woff2/.woff/.ttf). */
  files?: string[];
  license?:
    | "OFL"
    | "Apache-2.0"
    | "MIT"
    | "Commercial-Unknown"
    | "System"
    | "Unknown";
  classification?:
    | "sans-body"
    | "sans-display"
    | "serif-body"
    | "serif-display"
    | "mono"
    | "script"
    | "display"
    | "unknown";
  role?:
    | "primary-display"
    | "primary-body"
    | "secondary"
    | "accent"
    | "unknown"
    | null;
}

/**
 * Optional side-quest data returned by `/brand/:domain?include=…`.
 * Each field is independently absent if the upstream call failed or
 * the field wasn't requested in `include`.
 */
export interface BrandExtras {
  fonts?: BrandFont[];
  styleguide?: unknown;
  screenshot_url?: string | null;
}

export interface BrandFetchResult {
  brand: Brand;
  cached: boolean;
  extras?: BrandExtras;
}

export interface BrandFetchOptions {
  /**
   * Which side-quests to include in the response. Default: none —
   * core brand record only. For the director's pre-generation pass
   * you almost always want `["fonts", "screenshot"]` at minimum.
   *
   * Pass `["all"]` to request every supported field.
   */
  include?: Array<"fonts" | "styleguide" | "screenshot" | "all">;
}

export interface BrandProductResult {
  status: string;
  product?: {
    name?: string;
    description?: string;
    price?: { amount?: number; currency?: string };
    images?: string[];
    features?: string[];
    sku?: string;
    url?: string;
  };
}

export interface BrandStyleguide {
  status: string;
  domain: string;
  styleguide: Record<string, unknown>;
}

export interface BrandFonts {
  status: string;
  domain: string;
  fonts: Array<{
    font: string;
    fallbacks?: string[];
    uses?: string[];
    num_elements?: number;
    num_words?: number;
    percent_elements?: number;
    percent_words?: number;
  }>;
}

export interface BrandScreenshot {
  status: string;
  domain: string;
  screenshot: string;
  screenshotType?: string;
  width?: number;
  height?: number;
}

/**
 * Normalised design tokens for a brand — palette, typography, voice.
 * Flat shape designed for agent consumption; aggregates context.dev's
 * brand-retrieve + styleguide + fonts endpoints. Reserved fields
 * (radii / spacing_rhythm / gradients) are populated by a follow-up
 * Browser Rendering enrichment pass and arrive as `null` in v1.
 */
export interface DesignTokens {
  domain: string;
  fetched_at: number;
  palette: {
    primary: string | null;
    secondary: string | null;
    accent: string | null;
    neutrals: string[];
    all: string[];
  };
  fonts: Array<{
    family: string;
    fallbacks: string[];
    dominance: number | null;
    uses: string[];
  }>;
  voice: {
    name: string | null;
    slogan: string | null;
    description: string | null;
  };
  radii: null;
  spacing_rhythm: null;
  gradients: null;
  sources: {
    brand: string;
    styleguide: string;
    fonts: string;
  };
}

export interface MetaAdAccount {
  id: string;
  account_id: string;
  name?: string;
  account_status?: number;
}

export interface MetaAd {
  source: "meta";
  external_id: string;
  url: string | null;
  body: string | null;
  cta: string | null;
  first_seen_at: number;
  last_seen_at: number;
  raw_json: Record<string, unknown>;
}

export interface MetaAdsResult {
  source: "meta";
  count: number;
  ads: MetaAd[];
}

export interface GoogleAdsResult {
  brand: string | null;
  advertiser_id: string | null;
  advertiser_url: string | null;
  creative_ids: string[];
  markdown_excerpt: string | null;
  source: "direct" | "social-data+firecrawl" | "exa+firecrawl" | "no_match";
  warning?: string;
}

export interface AdsSearchResult {
  ads: Ad[];
  source: AdSource | "all" | "exa";
  query: string;
  count: number;
}

export type HandleSource = "brand_socials" | "linktree" | "domain_guess";

export interface BriefResult {
  domain: string;
  handle: string;
  resolved_handles: {
    instagram: string;
    tiktok: string;
    youtube: string;
    twitter: string;
    facebook: string;
  };
  /** Where each handle came from. domain_guess = low confidence (the handle was
   * inferred from the second-level domain because no brand.socials or linktree
   * entry covered that platform). brand_socials = highest confidence. */
  resolved_handles_source: {
    instagram: HandleSource;
    tiktok: HandleSource;
    youtube: HandleSource;
    twitter: HandleSource;
    facebook: HandleSource;
  };
  generated_at: number;
  brand: { brand: Brand; cached: boolean } | null;
  design: {
    mode: "light" | "dark" | null;
    fonts: string[];
    typography: Record<string, unknown> | null;
    components: string[];
  };
  social: {
    instagram: Record<string, unknown> | null;
    tiktok: Record<string, unknown> | null;
    youtube: Record<string, unknown> | null;
    twitter: Record<string, unknown> | null;
    facebook: Record<string, unknown> | null;
    linktree: Record<string, unknown> | null;
  };
  ads: {
    meta: {
      /** Ads returned in this page. NOT a total — see has_more. */
      count: number;
      /** True if the upstream returned a pagination cursor. */
      has_more: boolean;
      /** Cursor for the next page (when has_more). */
      next_cursor: string | null;
      ads: unknown[];
    } | null;
    google: {
      advertiser_id: string | null;
      advertiser_url: string | null;
      creative_ids: string[];
      /** Number of creatives extracted from the visible advertiser page. */
      creative_count: number;
    } | null;
  };
  errors: Array<{ section: string; message: string }>;
}

/** Tier identifier returned in ScrapeFetchResult.source and attempts[]. */
export type ScrapeFetchTier =
  | "direct"
  | "cf-browser"
  | "context-dev"
  | "firecrawl"
  | "exa-fallback";

/** Per-attempt record in ScrapeFetchResult.attempts[]. */
export interface ScrapeFetchAttempt {
  tier: ScrapeFetchTier;
  status: number;
  ms: number;
  error?: string;
}

/**
 * Result from POST /scrape.  Matches the FetchResult shape from
 * apps/api/src/scrape/fetch-brand.ts — binary buffers are base64-encoded
 * in buffer_b64 instead of the raw ArrayBuffer.
 */
export interface ScrapeFetchResult {
  ok: boolean;
  /** Text content (HTML, CSS, SVG). Present for non-image fetches. */
  body?: string;
  /** Base64-encoded binary content (images, fonts). */
  buffer_b64?: string;
  contentType?: string;
  source: ScrapeFetchTier;
  status: number;
  fetch_ms: number;
  attempts: ScrapeFetchAttempt[];
}

// ── Resolve types ─────────────────────────────────────────────────────────────

export interface ResolveCandidate {
  domain: string;
  confidence: number;
  source: "direct_guess" | "web_search" | "wikipedia" | "llm_fallback";
  rationale: string;
  verified: boolean;
}

export interface ResolveRejected {
  domain: string;
  reason: string;
}

export interface ResolveCostLineItem {
  kind: "exa" | "wikipedia" | "llm" | "fetch" | "other";
  /** Free-form description; shape varies by kind. */
  [k: string]: unknown;
}

export interface ResolveCost {
  capability: string;
  /** What brandnana paid the upstream providers. */
  usd_at_cost: number;
  /** What the end user is billed (= usd_at_cost × margin). */
  usd_with_margin: number;
  /** Margin multiplier in effect when this resolve ran. */
  margin: number;
  items: ResolveCostLineItem[];
}

export interface ResolveResult {
  query: string;
  candidates: ResolveCandidate[];
  recommended: number | null;
  rejected: ResolveRejected[];
  /** Per-call cost breakdown, sourced from real upstream usage (not a table lookup). */
  cost?: ResolveCost;
}

export class BrandnanaError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body?: unknown,
  ) {
    super(message);
    this.name = "BrandnanaError";
  }
}

interface CallOptions {
  method?: string;
  body?: unknown;
  query?: Record<string, string | number | undefined>;
  /** Defaults to true except for /health */
  authenticated?: boolean;
}

export class BrandnanaClient {
  readonly baseUrl: string;
  readonly health = {
    get: (): Promise<HealthStatus> => this.call<HealthStatus>("/health", { authenticated: false }),
  };

  readonly brand = {
    fetch: (
      domain: string,
      opts: BrandFetchOptions = {},
    ): Promise<BrandFetchResult> =>
      this.call<BrandFetchResult>(`/brand/${encodeURIComponent(domain)}`, {
        query:
          opts.include && opts.include.length > 0
            ? { include: opts.include.join(",") }
            : undefined,
      }),
    styleguide: (domain: string): Promise<BrandStyleguide> =>
      this.call<BrandStyleguide>(`/brand/${encodeURIComponent(domain)}/styleguide`),
    fonts: (domain: string): Promise<BrandFonts> =>
      this.call<BrandFonts>(`/brand/${encodeURIComponent(domain)}/fonts`),
    screenshot: (domain: string): Promise<BrandScreenshot> =>
      this.call<BrandScreenshot>(`/brand/${encodeURIComponent(domain)}/screenshot`),
    /**
     * Pull a single product page (name, price, images, features) from
     * the given URL. Used by the wavelet director to attach product
     * hero assets to a brief.
     */
    product: (domain: string, url: string): Promise<BrandProductResult> =>
      this.call<BrandProductResult>(`/brand/${encodeURIComponent(domain)}/product`, {
        query: { url },
      }),
  };

  readonly design = {
    tokens: (domain: string): Promise<DesignTokens> =>
      this.call<DesignTokens>(`/design/tokens/${encodeURIComponent(domain)}`),
  };

  readonly catalog = {
    crawl: (req: CatalogCrawlRequest): AsyncIterable<CatalogRow> =>
      this.stream<CatalogRow>("/catalog/crawl", {
        method: "POST",
        body: {
          domain: req.domain,
          strategy: req.strategy ?? "auto",
          brand_id: req.brandId,
          max_urls: req.maxUrls,
        },
      }),
    /** Current crawl state from the DO. `status: "idle"` if none ever ran. */
    status: (domain: string): Promise<CatalogCrawlStatus> =>
      this.call<CatalogCrawlStatus>(`/catalog/status/${encodeURIComponent(domain)}`),
  };

  readonly brief = {
    get: (domain: string, handle?: string): Promise<BriefResult> =>
      this.call<BriefResult>(`/brief/${encodeURIComponent(domain)}`, {
        query: handle ? { handle } : undefined,
      }),
  };

  readonly ads = {
    search: (req: AdsSearchRequest): Promise<AdsSearchResult> =>
      this.call<AdsSearchResult>("/ads/search", {
        method: "POST",
        body: { query: req.query, source: req.source, limit: req.limit, brand: req.brand },
      }),
    sync: (req: AdsSyncRequest): Promise<AdsSyncResult> =>
      this.call<AdsSyncResult>("/ads/sync", {
        method: "POST",
        body: { source: req.source, brand: req.brand },
      }),
    meta: {
      accounts: (): Promise<{ accounts: MetaAdAccount[] }> =>
        this.call<{ accounts: MetaAdAccount[] }>("/ads/meta/accounts"),
      fetch: (adAccountId: string, limit?: number): Promise<MetaAdsResult> =>
        this.call<MetaAdsResult>("/ads/meta", {
          method: "POST",
          body: { ad_account_id: adAccountId, limit },
        }),
    },
    google: (req: { brand?: string; advertiserUrl?: string }): Promise<GoogleAdsResult> =>
      this.call<GoogleAdsResult>("/ads/google", {
        method: "POST",
        body: { brand: req.brand, advertiser_url: req.advertiserUrl },
      }),
  };

  readonly social = {
    instagram: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/instagram/${encodeURIComponent(handle)}`),
      posts: (handle: string): Promise<unknown> =>
        this.call(`/social/instagram/${encodeURIComponent(handle)}/posts`),
      reels: (handle: string): Promise<unknown> =>
        this.call(`/social/instagram/${encodeURIComponent(handle)}/reels`),
      highlights: (handle: string): Promise<unknown> =>
        this.call(`/social/instagram/${encodeURIComponent(handle)}/highlights`),
      post: (url: string): Promise<unknown> =>
        this.call("/social/instagram/post", { method: "POST", body: { url } }),
      postComments: (url: string): Promise<unknown> =>
        this.call("/social/instagram/post/comments", { method: "POST", body: { url } }),
      mediaTranscript: (url: string): Promise<unknown> =>
        this.call("/social/instagram/media/transcript", { method: "POST", body: { url } }),
      reelsSearch: (q: string): Promise<unknown> =>
        this.call("/social/instagram-reels-search", { query: { q } }),
    },
    facebookMarketplace: {
      search: (q: string): Promise<unknown> =>
        this.call("/social/facebook-marketplace/search", { query: { q } }),
      item: (url: string): Promise<unknown> =>
        this.call("/social/facebook-marketplace/item", { method: "POST", body: { url } }),
    },
    facebookEvents: {
      search: (q: string): Promise<unknown> =>
        this.call("/social/facebook-events/search", { query: { q } }),
      details: (url: string): Promise<unknown> =>
        this.call("/social/facebook-events/details", { method: "POST", body: { url } }),
    },
    tiktok: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/tiktok/${encodeURIComponent(handle)}`),
      videos: (handle: string): Promise<unknown> =>
        this.call(`/social/tiktok/${encodeURIComponent(handle)}/videos`),
      followers: (handle: string): Promise<unknown> =>
        this.call(`/social/tiktok/${encodeURIComponent(handle)}/followers`),
      following: (handle: string): Promise<unknown> =>
        this.call(`/social/tiktok/${encodeURIComponent(handle)}/following`),
      live: (handle: string): Promise<unknown> =>
        this.call(`/social/tiktok/${encodeURIComponent(handle)}/live`),
      video: (url: string): Promise<unknown> =>
        this.call("/social/tiktok/video", { method: "POST", body: { url } }),
      videoComments: (url: string): Promise<unknown> =>
        this.call("/social/tiktok/video/comments", { method: "POST", body: { url } }),
      videoTranscript: (url: string): Promise<unknown> =>
        this.call("/social/tiktok/video/transcript", { method: "POST", body: { url } }),
      searchUsers: (q: string): Promise<unknown> =>
        this.call("/social/tiktok/search/users", { query: { q } }),
      searchHashtag: (q: string): Promise<unknown> =>
        this.call("/social/tiktok/search/hashtag", { query: { q } }),
      searchKeyword: (q: string): Promise<unknown> =>
        this.call("/social/tiktok/search/keyword", { query: { q } }),
      searchTop: (q: string): Promise<unknown> =>
        this.call("/social/tiktok/search/top", { query: { q } }),
      trendingCreators: (): Promise<unknown> => this.call("/social/tiktok/trending/creators"),
      trendingHashtags: (): Promise<unknown> => this.call("/social/tiktok/trending/hashtags"),
      trendingFeed: (): Promise<unknown> => this.call("/social/tiktok/trending/feed"),
      song: (id: string): Promise<unknown> =>
        this.call(`/social/tiktok/song/${encodeURIComponent(id)}`),
      songVideos: (id: string): Promise<unknown> =>
        this.call(`/social/tiktok/song/${encodeURIComponent(id)}/videos`),
    },
    linkedin: {
      ads: (q: string): Promise<unknown> => this.call("/social/linkedin/ads", { query: { q } }),
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/linkedin/profile/${encodeURIComponent(handle)}`),
      company: (handle: string): Promise<unknown> =>
        this.call(`/social/linkedin/company/${encodeURIComponent(handle)}`),
      companyPosts: (handle: string): Promise<unknown> =>
        this.call(`/social/linkedin/company/${encodeURIComponent(handle)}/posts`),
      post: (url: string): Promise<unknown> =>
        this.call("/social/linkedin/post", { method: "POST", body: { url } }),
    },
    youtube: {
      channel: (handle: string): Promise<unknown> =>
        this.call(`/social/youtube/${encodeURIComponent(handle)}`),
      videos: (handle: string): Promise<unknown> =>
        this.call(`/social/youtube/${encodeURIComponent(handle)}/videos`),
      shorts: (handle: string): Promise<unknown> =>
        this.call(`/social/youtube/${encodeURIComponent(handle)}/shorts`),
      video: (url: string): Promise<unknown> =>
        this.call("/social/youtube/video", { method: "POST", body: { url } }),
      videoTranscript: (url: string): Promise<unknown> =>
        this.call("/social/youtube/video/transcript", { method: "POST", body: { url } }),
      videoComments: (url: string): Promise<unknown> =>
        this.call("/social/youtube/video/comments", { method: "POST", body: { url } }),
      search: (q: string): Promise<unknown> =>
        this.call("/social/youtube/search", { query: { q } }),
      searchHashtag: (q: string): Promise<unknown> =>
        this.call("/social/youtube/search/hashtag", { query: { q } }),
      trendingShorts: (): Promise<unknown> => this.call("/social/youtube/trending/shorts"),
    },
    twitter: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/twitter/${encodeURIComponent(handle)}`),
      tweets: (handle: string): Promise<unknown> =>
        this.call(`/social/twitter/${encodeURIComponent(handle)}/tweets`),
      tweet: (url: string): Promise<unknown> =>
        this.call("/social/twitter/tweet", { method: "POST", body: { url } }),
      tweetTranscript: (url: string): Promise<unknown> =>
        this.call("/social/twitter/tweet/transcript", { method: "POST", body: { url } }),
    },
    facebook: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/facebook/${encodeURIComponent(handle)}`),
      posts: (handle: string): Promise<unknown> =>
        this.call(`/social/facebook/${encodeURIComponent(handle)}/posts`),
      reels: (handle: string): Promise<unknown> =>
        this.call(`/social/facebook/${encodeURIComponent(handle)}/reels`),
      photos: (handle: string): Promise<unknown> =>
        this.call(`/social/facebook/${encodeURIComponent(handle)}/photos`),
      post: (url: string): Promise<unknown> =>
        this.call("/social/facebook/post", { method: "POST", body: { url } }),
      postComments: (url: string): Promise<unknown> =>
        this.call("/social/facebook/post/comments", { method: "POST", body: { url } }),
    },
    reddit: {
      subreddit: (name: string): Promise<unknown> =>
        this.call(`/social/reddit/${encodeURIComponent(name)}`),
      subredditDetails: (name: string): Promise<unknown> =>
        this.call(`/social/reddit/${encodeURIComponent(name)}/details`),
      subredditSearch: (name: string, q: string): Promise<unknown> =>
        this.call(`/social/reddit/${encodeURIComponent(name)}/search`, { query: { q } }),
      postComments: (url: string): Promise<unknown> =>
        this.call("/social/reddit/post/comments", { method: "POST", body: { url } }),
      search: (q: string): Promise<unknown> => this.call("/social/reddit-search", { query: { q } }),
    },
    tiktokShop: {
      search: (q: string): Promise<unknown> =>
        this.call("/social/tiktok-shop/search", { query: { q } }),
      shopProducts: (shopId: string): Promise<unknown> =>
        this.call(`/social/tiktok-shop/${encodeURIComponent(shopId)}/products`),
      product: (url: string): Promise<unknown> =>
        this.call("/social/tiktok-shop/product", { method: "POST", body: { url } }),
      productReviews: (url: string): Promise<unknown> =>
        this.call("/social/tiktok-shop/product/reviews", { method: "POST", body: { url } }),
      showcase: (handle: string): Promise<unknown> =>
        this.call(`/social/tiktok-shop/showcase/${encodeURIComponent(handle)}`),
    },
    threads: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/threads/${encodeURIComponent(handle)}`),
      posts: (handle: string): Promise<unknown> =>
        this.call(`/social/threads/${encodeURIComponent(handle)}/posts`),
      post: (url: string): Promise<unknown> =>
        this.call("/social/threads/post", { method: "POST", body: { url } }),
      search: (q: string): Promise<unknown> =>
        this.call("/social/threads-search", { query: { q } }),
      searchUsers: (q: string): Promise<unknown> =>
        this.call("/social/threads-search/users", { query: { q } }),
    },
    pinterest: {
      search: (q: string): Promise<unknown> =>
        this.call("/social/pinterest/search", { query: { q } }),
      boards: (handle: string): Promise<unknown> =>
        this.call(`/social/pinterest/boards/${encodeURIComponent(handle)}`),
      pin: (url: string): Promise<unknown> =>
        this.call("/social/pinterest/pin", { method: "POST", body: { url } }),
      board: (url: string): Promise<unknown> =>
        this.call("/social/pinterest/board", { method: "POST", body: { url } }),
    },
    links: {
      fetch: (
        platform: "linktree" | "komi" | "pillar" | "linkbio" | "linkme",
        handle: string,
      ): Promise<unknown> => this.call(`/social/links/${platform}/${encodeURIComponent(handle)}`),
    },
    bluesky: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/bluesky/${encodeURIComponent(handle)}`),
      posts: (handle: string): Promise<unknown> =>
        this.call(`/social/bluesky/${encodeURIComponent(handle)}/posts`),
      post: (url: string): Promise<unknown> =>
        this.call("/social/bluesky/post", { method: "POST", body: { url } }),
    },
    twitch: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/twitch/${encodeURIComponent(handle)}`),
      videos: (handle: string): Promise<unknown> =>
        this.call(`/social/twitch/${encodeURIComponent(handle)}/videos`),
      schedule: (handle: string): Promise<unknown> =>
        this.call(`/social/twitch/${encodeURIComponent(handle)}/schedule`),
      clip: (url: string): Promise<unknown> =>
        this.call("/social/twitch/clip", { method: "POST", body: { url } }),
    },
    spotify: {
      artist: (url: string): Promise<unknown> =>
        this.call("/social/spotify/artist", { method: "POST", body: { url } }),
      track: (url: string): Promise<unknown> =>
        this.call("/social/spotify/track", { method: "POST", body: { url } }),
      album: (url: string): Promise<unknown> =>
        this.call("/social/spotify/album", { method: "POST", body: { url } }),
    },
    rumble: {
      search: (q: string): Promise<unknown> => this.call("/social/rumble-search", { query: { q } }),
      channelVideos: (handle: string): Promise<unknown> =>
        this.call(`/social/rumble/${encodeURIComponent(handle)}/videos`),
      video: (url: string): Promise<unknown> =>
        this.call("/social/rumble/video", { method: "POST", body: { url } }),
      videoTranscript: (url: string): Promise<unknown> =>
        this.call("/social/rumble/video/transcript", { method: "POST", body: { url } }),
    },
    soundcloud: {
      artist: (url: string): Promise<unknown> =>
        this.call("/social/soundcloud/artist", { method: "POST", body: { url } }),
      artistTracks: (url: string): Promise<unknown> =>
        this.call("/social/soundcloud/artist/tracks", { method: "POST", body: { url } }),
      track: (url: string): Promise<unknown> =>
        this.call("/social/soundcloud/track", { method: "POST", body: { url } }),
    },
    truthsocial: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/truthsocial/${encodeURIComponent(handle)}`),
      posts: (handle: string): Promise<unknown> =>
        this.call(`/social/truthsocial/${encodeURIComponent(handle)}/posts`),
      post: (url: string): Promise<unknown> =>
        this.call("/social/truthsocial/post", { method: "POST", body: { url } }),
    },
    snapchat: {
      profile: (handle: string): Promise<unknown> =>
        this.call(`/social/snapchat/${encodeURIComponent(handle)}`),
    },
    kick: {
      clip: (url: string): Promise<unknown> =>
        this.call("/social/kick/clip", { method: "POST", body: { url } }),
    },
    googleExtras: {
      search: (q: string): Promise<unknown> => this.call("/social/google-search", { query: { q } }),
      advertiserAds: (advertiserId: string): Promise<unknown> =>
        this.call(`/social/google-ads/advertiser/${encodeURIComponent(advertiserId)}`),
      ad: (url: string): Promise<unknown> =>
        this.call("/social/google-ads/ad", { method: "POST", body: { url } }),
    },
  };

  readonly resolve = {
    /**
     * Find the canonical domain for an ambiguous brand reference.
     * Returns ranked candidates from direct guesses, Exa search,
     * Wikipedia infobox, and LLM fallback.
     */
    query: (query: string, limit?: number): Promise<ResolveResult> =>
      this.call<ResolveResult>("/v1/resolve", {
        method: "POST",
        body: { query, limit },
      }),
  };

  readonly scrape = {
    /**
     * Generic tiered brand-asset fetcher.
     * Routes through direct → cf-browser → context-dev → firecrawl.
     * Returns the FetchResult from whichever tier succeeded first.
     */
    fetch: (
      url: string,
      opts?: { expect?: "html" | "image" | "css" | "any"; skipTiers?: string[] },
    ): Promise<ScrapeFetchResult> =>
      this.call<ScrapeFetchResult>("/scrape", {
        method: "POST",
        body: { url, expect: opts?.expect, skipTiers: opts?.skipTiers },
      }),
  };

  readonly mirror = {
    images: (urls: string[]): Promise<MirrorResult> =>
      this.call<MirrorResult>("/mirror/images", { method: "POST", body: { urls } }),
  };

  readonly usage = {
    get: (sinceHours?: number): Promise<UsageReport> =>
      this.call<UsageReport>("/usage", {
        query: { since_hours: sinceHours },
      }),
  };

  readonly auth = {
    start: (req: AuthProvider): Promise<AuthStartResult> =>
      this.call<AuthStartResult>(`/auth/${req.provider}/start`, { method: "POST" }),
    status: (provider: AdSource, sessionId: string): Promise<AuthStatus> =>
      this.call<AuthStatus>(`/auth/${provider}/status`, { query: { session: sessionId } }),
    connections: (): Promise<AuthConnection[]> => this.call<AuthConnection[]>("/auth/connections"),
  };

  private readonly fetchFn: typeof globalThis.fetch;
  private readonly apiKey: string;
  private readonly callTimeoutMs: number;
  private readonly streamIdleMs: number;

  constructor(opts: BrandnanaClientOptions) {
    if (!opts.apiKey) {
      throw new Error("BrandnanaClient: apiKey is required");
    }
    this.apiKey = opts.apiKey;
    this.baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.fetchFn = opts.fetch ?? globalThis.fetch.bind(globalThis);
    this.callTimeoutMs = opts.callTimeoutMs ?? 120_000;
    this.streamIdleMs = opts.streamIdleMs ?? 90_000;
  }

  private buildUrl(path: string, query?: CallOptions["query"]): string {
    const url = new URL(this.baseUrl + (path.startsWith("/") ? path : `/${path}`));
    if (query) {
      for (const [k, v] of Object.entries(query)) {
        if (v === undefined) continue;
        url.searchParams.set(k, String(v));
      }
    }
    return url.toString();
  }

  private buildHeaders(authenticated: boolean, hasBody: boolean): Headers {
    const headers = new Headers();
    if (authenticated) {
      headers.set("authorization", `Bearer ${this.apiKey}`);
    }
    if (hasBody) {
      headers.set("content-type", "application/json");
    }
    headers.set("accept", "application/json");
    return headers;
  }

  async call<T>(path: string, opts: CallOptions = {}): Promise<T> {
    const url = this.buildUrl(path, opts.query);
    const init: RequestInit = {
      method: opts.method ?? "GET",
      headers: this.buildHeaders(opts.authenticated !== false, opts.body !== undefined),
      signal: AbortSignal.timeout(this.callTimeoutMs),
    };
    if (opts.body !== undefined) {
      init.body = JSON.stringify(opts.body);
    }
    let res: Response;
    try {
      res = await this.fetchFn(url, init);
    } catch (e) {
      // A timeout abort surfaces as a loud BrandnanaError (status 408) that
      // propagates to runAction→emitError (exit 1), instead of the request
      // being silently truncated by the outer bash timeout.
      if (e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError")) {
        throw new BrandnanaError(`Brandnana API request timed out after ${this.callTimeoutMs}ms (${path})`, 408);
      }
      throw e;
    }
    if (!res.ok) {
      let body: unknown;
      try {
        body = await res.json();
      } catch {
        body = await res.text().catch(() => undefined);
      }
      throw new BrandnanaError(
        `Brandnana API ${res.status} ${res.statusText} (${path})`,
        res.status,
        body,
      );
    }
    if (res.status === 204) {
      return undefined as T;
    }
    return (await res.json()) as T;
  }

  async *stream<T>(path: string, opts: CallOptions = {}): AsyncIterable<T> {
    const url = this.buildUrl(path, opts.query);
    const headers = this.buildHeaders(opts.authenticated !== false, opts.body !== undefined);
    headers.set("accept", "application/x-ndjson");
    // IDLE timeout: abort only if NO chunk arrives for streamIdleMs. A healthy
    // catalog crawl streams for minutes — we watch for a HUNG stream, not a slow
    // one — so the timer is reset on every chunk. A bare AbortSignal.timeout
    // would wrongly cut a long-but-healthy crawl.
    const controller = new AbortController();
    let idle: ReturnType<typeof setTimeout> | undefined;
    const resetIdle = () => {
      if (idle) clearTimeout(idle);
      idle = setTimeout(() => controller.abort(), this.streamIdleMs);
    };
    const init: RequestInit = {
      method: opts.method ?? "GET",
      headers,
      signal: controller.signal,
    };
    if (opts.body !== undefined) {
      init.body = JSON.stringify(opts.body);
    }
    resetIdle();
    let res: Response;
    try {
      res = await this.fetchFn(url, init);
    } catch (e) {
      if (idle) clearTimeout(idle);
      if (controller.signal.aborted) {
        throw new BrandnanaError(`Brandnana API stream idle >${this.streamIdleMs}ms (${path})`, 408);
      }
      throw e;
    }
    if (!res.ok || !res.body) {
      if (idle) clearTimeout(idle);
      const text = await res.text().catch(() => "");
      throw new BrandnanaError(
        `Brandnana API ${res.status} ${res.statusText} (${path})`,
        res.status,
        text,
      );
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        resetIdle(); // data arrived → push the idle deadline forward
        buffer += decoder.decode(value, { stream: true });
        let nl = buffer.indexOf("\n");
        while (nl !== -1) {
          const line = buffer.slice(0, nl).trim();
          buffer = buffer.slice(nl + 1);
          if (line) {
            yield JSON.parse(line) as T;
          }
          nl = buffer.indexOf("\n");
        }
      }
    } catch (e) {
      if (controller.signal.aborted) {
        throw new BrandnanaError(`Brandnana API stream idle >${this.streamIdleMs}ms (${path})`, 408);
      }
      throw e;
    } finally {
      if (idle) clearTimeout(idle);
    }
    const tail = buffer.trim();
    if (tail) {
      yield JSON.parse(tail) as T;
    }
  }
}

export function createBrandnanaClient(opts: BrandnanaClientOptions): BrandnanaClient {
  return new BrandnanaClient(opts);
}

export type { Ad, AdSource, Brand, Product, ProductImage, ProductPlatform };
