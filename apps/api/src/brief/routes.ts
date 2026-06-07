// GET /brief/:domain — one-shot cross-channel brand brief.
//
// Server-side fan-out across 9 calls (brand, IG, TT, YT, Twitter, FB,
// Linktree, Meta ads search, Google ads). Each leg is best-effort;
// failures land in errors[] and the rest still emits. Running this
// server-side instead of from the CLI saves 8 round-trips and keeps
// all the calls behind one /usage row.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { getFonts, getStyleguide, retrieveBrand } from "../scrape/context.js";
import { scrapeGoogleAds } from "../scrape/google_ads.js";
import { metaAdLibrarySearch } from "../scrape/scrapecreators.js";
import { facebook, instagram, linktree, tiktok, twitter, youtube } from "../scrape/social.js";

const brief = new Hono<{ Bindings: Bindings }>();
brief.use("*", requireBearer);

/** Where a resolved handle came from. Agents should treat domain_guess as low-confidence. */
type HandleSource = "brand_socials" | "linktree" | "domain_guess";

interface BriefResult {
  domain: string;
  handle: string;
  resolved_handles: {
    instagram: string;
    tiktok: string;
    youtube: string;
    twitter: string;
    facebook: string;
  };
  resolved_handles_source: {
    instagram: HandleSource;
    tiktok: HandleSource;
    youtube: HandleSource;
    twitter: HandleSource;
    facebook: HandleSource;
  };
  generated_at: number;
  brand: unknown | null;
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
      /** Number of ads returned in this page. NOT a total — see has_more. */
      count: number;
      /** True if the upstream returned a pagination cursor; the brand likely
       * has more ads than `count` suggests. */
      has_more: boolean;
      /** Cursor to pass to /ads/search for the next page, when has_more. */
      next_cursor: string | null;
      ads: unknown[];
    } | null;
    google: {
      advertiser_id: string | null;
      advertiser_url: string | null;
      creative_ids: string[];
      /** Number of creatives extracted from the visible advertiser page. There
       * is no upstream pagination here — the page is one rendered scrape — so
       * if creative_ids.length sits at a round number like 40, the brand may
       * have more ads beyond the fold that weren't captured. */
      creative_count: number;
    } | null;
  };
  errors: Array<{ section: string; message: string }>;
}

async function settle<T>(
  section: string,
  errors: BriefResult["errors"],
  fn: () => Promise<T>,
): Promise<T | undefined> {
  try {
    return await fn();
  } catch (e) {
    errors.push({ section, message: (e as Error).message });
    return undefined;
  }
}

function defaultHandle(domain: string): string {
  const stripped = domain.replace(/^www\./, "").split(".")[0] ?? domain;
  return stripped.toLowerCase();
}

interface ResolvedHandles {
  instagram: string;
  tiktok: string;
  youtube: string;
  twitter: string;
  facebook: string;
}

type ResolvedHandlesSource = Record<keyof ResolvedHandles, HandleSource>;

/**
 * Set platform handles from a list of URLs and tag each with `source`.
 * Later passes (with stronger sources) overwrite earlier ones.
 */
function resolveFromUrls(
  handles: ResolvedHandles,
  source: ResolvedHandlesSource,
  urls: Iterable<string>,
  tag: HandleSource,
): void {
  for (const raw of urls) {
    if (typeof raw !== "string") continue;
    let parsed: URL;
    try {
      parsed = new URL(raw);
    } catch {
      continue;
    }
    const host = parsed.host.replace(/^www\./, "");
    const segments = parsed.pathname.split("/").filter(Boolean);
    const first = segments[0]?.replace(/^@/, "");
    if (!first) continue;
    if (host.endsWith("instagram.com")) {
      handles.instagram = first;
      source.instagram = tag;
    } else if (host.endsWith("tiktok.com")) {
      handles.tiktok = first;
      source.tiktok = tag;
    } else if (host.endsWith("youtube.com") || host.endsWith("youtu.be")) {
      // Only adopt handle-style URLs (/@handle); skip /channel/UCxxx + /c/<name>
      // since the channel endpoint we wrap expects an @-handle, not a channel id.
      if (segments[0]?.startsWith("@")) {
        handles.youtube = segments[0].slice(1);
        source.youtube = tag;
      } else if (segments[0] !== "channel" && segments[0] !== "c" && segments[0] !== "user") {
        handles.youtube = first;
        source.youtube = tag;
      }
    } else if (host.endsWith("twitter.com") || host.endsWith("x.com")) {
      handles.twitter = first;
      source.twitter = tag;
    } else if (host.endsWith("facebook.com") || host.endsWith("fb.com")) {
      handles.facebook = first;
      source.facebook = tag;
    }
  }
}

/**
 * Resolve per-platform handles by walking, in order of trust:
 *   1. context.dev brand.socials (most accurate — they parse the site)
 *   2. linktree.links (if the brand publishes one)
 *   3. the fallback handle inferred from domain (low-confidence)
 *
 * Returns both the handle and the source it came from so agents can decide
 * whether to trust a profile lookup (e.g. domain_guess hits on @allbirds give
 * a 2-follower imposter; the real TT handle is @weareallbirds).
 */
function resolveHandles(
  fallback: string,
  brandData: unknown,
  linktreeData: unknown,
): { handles: ResolvedHandles; source: ResolvedHandlesSource } {
  const handles: ResolvedHandles = {
    instagram: fallback,
    tiktok: fallback,
    youtube: fallback,
    twitter: fallback,
    facebook: fallback,
  };
  const source: ResolvedHandlesSource = {
    instagram: "domain_guess",
    tiktok: "domain_guess",
    youtube: "domain_guess",
    twitter: "domain_guess",
    facebook: "domain_guess",
  };

  // Layer 2 (lowest trust source after fallback): linktree.links
  const links = (linktreeData as { links?: Array<{ url?: string }> })?.links;
  if (Array.isArray(links)) {
    resolveFromUrls(
      handles,
      source,
      links.map((l) => l?.url).filter((u): u is string => typeof u === "string"),
      "linktree",
    );
  }

  // Layer 1 (highest trust): brand.socials — applied last so it wins.
  const socials = (brandData as { brand?: { socials?: Array<{ url?: string }> } })?.brand?.socials;
  if (Array.isArray(socials)) {
    resolveFromUrls(
      handles,
      source,
      socials.map((s) => s?.url).filter((u): u is string => typeof u === "string"),
      "brand_socials",
    );
  }

  return { handles, source };
}

function summariseInstagram(ig: unknown): Record<string, unknown> | null {
  if (!ig || typeof ig !== "object") return null;
  const user = (ig as { data?: { user?: Record<string, unknown> } }).data?.user;
  if (!user) return null;
  return {
    username: user.username,
    full_name: user.full_name,
    biography: user.biography,
    followers: (user as { edge_followed_by?: { count?: number } }).edge_followed_by?.count,
    posts: (user as { edge_owner_to_timeline_media?: { count?: number } })
      .edge_owner_to_timeline_media?.count,
    verified: user.is_verified,
  };
}

function summariseTiktok(tt: unknown): Record<string, unknown> | null {
  if (!tt || typeof tt !== "object") return null;
  const user = (tt as { user?: Record<string, unknown> }).user;
  const stats = (tt as { stats?: Record<string, unknown> }).stats;
  if (!user) return null;
  return {
    username: user.uniqueId,
    nickname: user.nickname,
    bio: user.signature,
    followers: stats?.followerCount,
    following: stats?.followingCount,
    posts: stats?.videoCount,
    hearts: stats?.heartCount,
    verified: user.verified,
  };
}

function summariseYoutube(yt: unknown): Record<string, unknown> | null {
  if (!yt || typeof yt !== "object") return null;
  const d = yt as Record<string, unknown>;
  if (!d.channelId) return null;
  return {
    channel: d.channelId,
    title: d.channel,
    description: d.description,
    subscribers: d.subscriberCount,
    views: d.viewCount,
    videos: d.videoCount,
  };
}

function summariseTwitter(tw: unknown): Record<string, unknown> | null {
  if (!tw || typeof tw !== "object") return null;
  const core = (tw as { core?: Record<string, unknown> }).core;
  const legacy = (tw as { legacy?: Record<string, unknown> }).legacy;
  if (!core && !legacy) return null;
  return {
    screen_name: legacy?.screen_name ?? core?.screen_name,
    name: legacy?.name ?? core?.name,
    description: legacy?.description,
    followers: legacy?.followers_count,
    following: legacy?.friends_count,
    tweets: legacy?.statuses_count,
    verified: legacy?.verified,
  };
}

function summariseFacebook(fb: unknown): Record<string, unknown> | null {
  if (!fb || typeof fb !== "object") return null;
  const d = fb as Record<string, unknown>;
  if (!d.name) return null;
  return {
    page_id: d.id,
    name: d.name,
    creation_date: d.creationDate,
    category: d.category,
  };
}

brief.get("/:domain", async (c) => {
  const domain = c.req.param("domain");
  if (!domain || !/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(domain)) {
    return c.json({ error: "invalid_domain" }, 400);
  }
  const fallbackHandle = c.req.query("handle") ?? defaultHandle(domain);
  const user = c.get("user");
  const tenantOpts = { tenant: user.id, ctx: c.executionCtx };
  const errors: BriefResult["errors"] = [];

  // Phase 1: pull linktree (cheap, gives us real per-platform handles)
  // in parallel with the things that don't depend on platform handles.
  const [brand, styleguide, fonts, lt, metaAds, googleAds] = await Promise.all([
    settle("brand", errors, () => retrieveBrand(c.env, domain, user.id, c.executionCtx)),
    settle("styleguide", errors, () => getStyleguide(c.env, domain, user.id, c.executionCtx)),
    settle("fonts", errors, () => getFonts(c.env, domain, user.id, c.executionCtx)),
    settle("linktree", errors, () => linktree.fetch(c.env, fallbackHandle, tenantOpts)),
    settle("meta_ads", errors, () =>
      metaAdLibrarySearch(c.env, { query: fallbackHandle, country: "US", ...tenantOpts }),
    ),
    settle("google_ads", errors, () =>
      scrapeGoogleAds(c.env, { brand: fallbackHandle, ...tenantOpts }),
    ),
  ]);

  // Phase 2: fan out platform profile lookups using resolved handles.
  // Order of trust: context.dev brand.socials → linktree.links → fallback.
  const { handles: resolved, source: resolvedSource } = resolveHandles(fallbackHandle, brand, lt);
  const [ig, tt, yt, tw, fb] = await Promise.all([
    settle("instagram", errors, () => instagram.profile(c.env, resolved.instagram, tenantOpts)),
    settle("tiktok", errors, () => tiktok.profile(c.env, resolved.tiktok, tenantOpts)),
    settle("youtube", errors, () => youtube.channel(c.env, resolved.youtube, tenantOpts)),
    settle("twitter", errors, () => twitter.profile(c.env, resolved.twitter, tenantOpts)),
    settle("facebook", errors, () => facebook.profile(c.env, resolved.facebook, tenantOpts)),
  ]);

  // Normalise the brand response — retrieveBrand returns { status, brand }; we
  // want to mirror what GET /brand/:domain emits so the SDK type aligns.
  const brandPayload = brand?.brand
    ? {
        id: crypto.randomUUID(),
        domain,
        name: brand.brand.title ?? null,
        logo_url: brand.brand.logos?.[0]?.url ?? null,
        palette_json: brand.brand.colors
          ? JSON.stringify(brand.brand.colors.map((x) => x.hex))
          : null,
        descriptors_json: JSON.stringify({
          description: brand.brand.description ?? null,
          slogan: brand.brand.slogan ?? null,
        }),
        fetched_at: Date.now(),
      }
    : null;

  const sg = styleguide?.styleguide ?? null;
  const result: BriefResult = {
    domain,
    handle: fallbackHandle,
    resolved_handles: resolved,
    resolved_handles_source: resolvedSource,
    generated_at: Date.now(),
    brand: brandPayload ? { brand: brandPayload, cached: false } : null,
    design: {
      mode: (sg?.mode as "light" | "dark" | undefined) ?? null,
      fonts: (fonts?.fonts ?? []).map((f) => f.font).filter((f): f is string => !!f),
      typography: (sg?.typography as Record<string, unknown> | undefined) ?? null,
      components: sg?.components ? Object.keys(sg.components as Record<string, unknown>) : [],
    },
    social: {
      instagram: summariseInstagram(ig),
      tiktok: summariseTiktok(tt),
      youtube: summariseYoutube(yt),
      twitter: summariseTwitter(tw),
      facebook: summariseFacebook(fb),
      linktree: lt
        ? {
            username: (lt as { username?: string }).username,
            description: (lt as { description?: string }).description,
            link_count: Array.isArray((lt as { links?: unknown[] }).links)
              ? (lt as { links: unknown[] }).links.length
              : null,
          }
        : null,
    },
    ads: {
      meta: metaAds
        ? {
            count: metaAds.ads.length,
            has_more: metaAds.has_more,
            next_cursor: metaAds.cursor,
            ads: metaAds.ads.slice(0, 5),
          }
        : null,
      google: googleAds
        ? {
            advertiser_id: googleAds.advertiser_id,
            advertiser_url: googleAds.advertiser_url,
            creative_ids: googleAds.creative_ids,
            creative_count: googleAds.creative_ids.length,
          }
        : null,
    },
    errors,
  };

  return c.json(result);
});

export default brief;
