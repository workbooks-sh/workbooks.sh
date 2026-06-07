// /social/* — Instagram, TikTok, YouTube, Twitter/X, Facebook, Reddit,
// LinkedIn data routes. Wraps every non-ad social-data endpoint behind
// the brandnana URL space so users only see our routes, not the upstream.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import {
  bluesky,
  facebook,
  facebookEvents,
  facebookMarketplace,
  googleExtras,
  instagram,
  kick,
  komi,
  linkbio,
  linkedin,
  linkme,
  linktree,
  pillar,
  pinterest,
  reddit,
  rumble,
  snapchat,
  soundcloud,
  spotify,
  threads,
  tiktok,
  tiktokShop,
  truthsocial,
  twitch,
  twitter,
  youtube,
} from "../scrape/social.js";
import {
  summariseFacebook,
  summariseInstagram,
  summariseTiktok,
  summariseTwitter,
  summariseYoutube,
} from "./summary.js";

const social = new Hono<{ Bindings: Bindings }>();
social.use("*", requireBearer);

const NOT_CONFIGURED = { error: "not_configured", message: "social-data backend not configured" };
const UPSTREAM_UNAVAILABLE = {
  error: "upstream_unavailable",
  message:
    "social-data backend returned no data — could be rate-limited, the handle may not exist on this platform, or upstream is degraded. Retry or try a different handle.",
};

/** Pick the right HTTP error for a null wrapper return: 503 if the
 * upstream wasn't even configurable on this worker (deploy-time), 502
 * if it was configured but didn't return data (transient/runtime). */
function notFound(c: { env: Bindings; json: (b: unknown, s: number) => Response }) {
  if (!c.env.SCRAPECREATORS_API_KEY) return c.json(NOT_CONFIGURED, 503);
  return c.json(UPSTREAM_UNAVAILABLE, 502);
}

function requireQuery(
  c: { req: { query: (k: string) => string | undefined } },
  key: string,
): string | null {
  return c.req.query(key) ?? null;
}

/** True when caller passed ?raw=true on a profile endpoint, asking to bypass
 * the normalized {summary,raw} envelope and get the upstream JSON as-is. */
function wantsRaw(c: { req: { query: (k: string) => string | undefined } }): boolean {
  const v = c.req.query("raw");
  return v === "true" || v === "1";
}

/** Wrap a profile response with a normalized summary alongside the raw vendor
 * payload. Agents can read summary.followers without knowing each vendor's
 * field-naming quirks; power users pass ?raw=true to bypass the envelope. */
function profileResponse<T>(
  c: { req: { query: (k: string) => string | undefined }; json: (b: unknown) => Response },
  raw: T,
  summary: import("./summary.js").ProfileSummary | null,
): Response {
  if (wantsRaw(c)) return c.json(raw);
  return c.json({ summary, raw });
}

// -- Instagram ------------------------------------------------------------

social.get("/instagram/:handle", async (c) => {
  const user = c.get("user");
  const data = await instagram.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return profileResponse(c, data, summariseInstagram(data));
});

social.get("/instagram/:handle/posts", async (c) => {
  const user = c.get("user");
  const data = await instagram.userPosts(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/instagram/:handle/reels", async (c) => {
  const user = c.get("user");
  const data = await instagram.userReels(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/instagram/:handle/highlights", async (c) => {
  const user = c.get("user");
  const data = await instagram.userHighlights(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/instagram/post", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await instagram.post(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/instagram/post/comments", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await instagram.postComments(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/instagram/media/transcript", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await instagram.mediaTranscript(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/instagram-reels-search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await instagram.reelsSearch(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Facebook Marketplace + Events ----------------------------------------

social.get("/facebook-marketplace/search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await facebookMarketplace.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/facebook-marketplace/item", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await facebookMarketplace.item(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/facebook-events/search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await facebookEvents.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/facebook-events/details", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await facebookEvents.details(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- TikTok ---------------------------------------------------------------

social.get("/tiktok/:handle", async (c) => {
  const user = c.get("user");
  const data = await tiktok.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return profileResponse(c, data, summariseTiktok(data));
});

social.get("/tiktok/:handle/videos", async (c) => {
  const user = c.get("user");
  const data = await tiktok.profileVideos(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/:handle/followers", async (c) => {
  const user = c.get("user");
  const data = await tiktok.userFollowers(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/:handle/following", async (c) => {
  const user = c.get("user");
  const data = await tiktok.userFollowing(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/:handle/live", async (c) => {
  const user = c.get("user");
  const data = await tiktok.userLive(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// Tiktok content (URL-based)
social.post("/tiktok/video", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await tiktok.video(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/tiktok/video/comments", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await tiktok.videoComments(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/tiktok/video/transcript", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await tiktok.videoTranscript(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// TikTok search
social.get("/tiktok/search/users", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await tiktok.searchUsers(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/search/hashtag", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await tiktok.searchHashtag(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/search/keyword", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await tiktok.searchKeyword(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/search/top", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await tiktok.searchTop(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// TikTok trending
social.get("/tiktok/trending/creators", async (c) => {
  const user = c.get("user");
  const data = await tiktok.popularCreators(c.env, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/trending/hashtags", async (c) => {
  const user = c.get("user");
  const data = await tiktok.popularHashtags(c.env, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/trending/feed", async (c) => {
  const user = c.get("user");
  const data = await tiktok.trendingFeed(c.env, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// TikTok songs
social.get("/tiktok/song/:id", async (c) => {
  const user = c.get("user");
  const data = await tiktok.song(c.env, c.req.param("id"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok/song/:id/videos", async (c) => {
  const user = c.get("user");
  const data = await tiktok.songVideos(c.env, c.req.param("id"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- LinkedIn -------------------------------------------------------------

social.get("/linkedin/ads", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await linkedin.adSearch(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/linkedin/profile/:handle", async (c) => {
  const user = c.get("user");
  const data = await linkedin.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/linkedin/company/:handle", async (c) => {
  const user = c.get("user");
  const data = await linkedin.company(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/linkedin/company/:handle/posts", async (c) => {
  const user = c.get("user");
  const data = await linkedin.companyPosts(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/linkedin/post", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await linkedin.post(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- YouTube --------------------------------------------------------------

social.get("/youtube/:handle", async (c) => {
  const user = c.get("user");
  const data = await youtube.channel(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return profileResponse(c, data, summariseYoutube(data));
});

social.get("/youtube/:handle/videos", async (c) => {
  const user = c.get("user");
  const data = await youtube.channelVideos(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/youtube/:handle/shorts", async (c) => {
  const user = c.get("user");
  const data = await youtube.channelShorts(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/youtube/video", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await youtube.video(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/youtube/video/transcript", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await youtube.videoTranscript(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/youtube/video/comments", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await youtube.videoComments(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/youtube/search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await youtube.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/youtube/search/hashtag", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await youtube.searchHashtag(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/youtube/trending/shorts", async (c) => {
  const user = c.get("user");
  const data = await youtube.shortsTrending(c.env, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Twitter / X ----------------------------------------------------------

social.get("/twitter/:handle", async (c) => {
  const user = c.get("user");
  const data = await twitter.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return profileResponse(c, data, summariseTwitter(data));
});

social.get("/twitter/:handle/tweets", async (c) => {
  const user = c.get("user");
  const data = await twitter.userTweets(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/twitter/tweet", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await twitter.tweet(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/twitter/tweet/transcript", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await twitter.tweetTranscript(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Facebook (profile / posts) -------------------------------------------

social.get("/facebook/:handle", async (c) => {
  const user = c.get("user");
  const data = await facebook.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return profileResponse(c, data, summariseFacebook(data));
});

social.get("/facebook/:handle/posts", async (c) => {
  const user = c.get("user");
  const data = await facebook.profilePosts(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/facebook/:handle/reels", async (c) => {
  const user = c.get("user");
  const data = await facebook.profileReels(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/facebook/:handle/photos", async (c) => {
  const user = c.get("user");
  const data = await facebook.profilePhotos(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/facebook/post", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await facebook.post(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/facebook/post/comments", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await facebook.postComments(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Reddit ---------------------------------------------------------------

social.get("/reddit/:name", async (c) => {
  const user = c.get("user");
  const data = await reddit.subreddit(c.env, c.req.param("name"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/reddit/:name/details", async (c) => {
  const user = c.get("user");
  const data = await reddit.subredditDetails(c.env, c.req.param("name"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/reddit/:name/search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await reddit.subredditSearch(c.env, c.req.param("name"), q, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/reddit/post/comments", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await reddit.postComments(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/reddit-search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await reddit.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- TikTok Shop ---------------------------------------------------------

social.get("/tiktok-shop/search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await tiktokShop.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok-shop/:shopId/products", async (c) => {
  const user = c.get("user");
  const data = await tiktokShop.shopProducts(c.env, c.req.param("shopId"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/tiktok-shop/product", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await tiktokShop.product(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/tiktok-shop/product/reviews", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await tiktokShop.productReviews(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/tiktok-shop/showcase/:handle", async (c) => {
  const user = c.get("user");
  const data = await tiktokShop.userShowcase(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Threads -------------------------------------------------------------

social.get("/threads/:handle", async (c) => {
  const user = c.get("user");
  const data = await threads.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/threads/:handle/posts", async (c) => {
  const user = c.get("user");
  const data = await threads.userPosts(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/threads/post", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await threads.post(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/threads-search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await threads.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/threads-search/users", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await threads.searchUsers(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Pinterest -----------------------------------------------------------

social.get("/pinterest/search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await pinterest.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/pinterest/boards/:handle", async (c) => {
  const user = c.get("user");
  const data = await pinterest.userBoards(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/pinterest/pin", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await pinterest.pin(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/pinterest/board", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await pinterest.board(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Link aggregators ----------------------------------------------------
// Pattern: /social/links/:platform/:handle — platform is linktree, komi,
// pillar, linkbio, or linkme.

const LINK_AGG = {
  linktree: linktree.fetch,
  komi: komi.fetch,
  pillar: pillar.fetch,
  linkbio: linkbio.fetch,
  linkme: linkme.fetch,
} as const;

social.get("/links/:platform/:handle", async (c) => {
  const platform = c.req.param("platform") as keyof typeof LINK_AGG;
  const handle = c.req.param("handle");
  const fn = LINK_AGG[platform];
  if (!fn)
    return c.json(
      { error: "unknown_platform", message: `try one of: ${Object.keys(LINK_AGG).join(", ")}` },
      400,
    );
  const user = c.get("user");
  const data = await fn(c.env, handle, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Bluesky -------------------------------------------------------------

social.get("/bluesky/:handle", async (c) => {
  const user = c.get("user");
  const data = await bluesky.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/bluesky/:handle/posts", async (c) => {
  const user = c.get("user");
  const data = await bluesky.userPosts(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/bluesky/post", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await bluesky.post(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Twitch --------------------------------------------------------------

social.get("/twitch/:handle", async (c) => {
  const user = c.get("user");
  const data = await twitch.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/twitch/:handle/videos", async (c) => {
  const user = c.get("user");
  const data = await twitch.userVideos(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/twitch/:handle/schedule", async (c) => {
  const user = c.get("user");
  const data = await twitch.userSchedule(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/twitch/clip", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await twitch.clip(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Spotify -------------------------------------------------------------

social.post("/spotify/artist", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await spotify.artist(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/spotify/track", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await spotify.track(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/spotify/album", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await spotify.album(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Rumble --------------------------------------------------------------

social.get("/rumble-search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await rumble.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/rumble/:handle/videos", async (c) => {
  const user = c.get("user");
  const data = await rumble.channelVideos(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/rumble/video", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await rumble.video(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/rumble/video/transcript", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await rumble.videoTranscript(c.env, body.url, {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- SoundCloud ----------------------------------------------------------

for (const [path, fn] of [
  ["/soundcloud/artist", soundcloud.artist],
  ["/soundcloud/artist/tracks", soundcloud.artistTracks],
  ["/soundcloud/track", soundcloud.track],
] as const) {
  social.post(path, async (c) => {
    const user = c.get("user");
    const body = (await c.req.json().catch(() => ({}))) as { url?: string };
    if (!body.url) return c.json({ error: "missing_url" }, 400);
    const data = await fn(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
    if (!data) return notFound(c);
    return c.json(data);
  });
}

// -- Truth Social --------------------------------------------------------

social.get("/truthsocial/:handle", async (c) => {
  const user = c.get("user");
  const data = await truthsocial.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/truthsocial/:handle/posts", async (c) => {
  const user = c.get("user");
  const data = await truthsocial.userPosts(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/truthsocial/post", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await truthsocial.post(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Snapchat / Kick -----------------------------------------------------

social.get("/snapchat/:handle", async (c) => {
  const user = c.get("user");
  const data = await snapchat.profile(c.env, c.req.param("handle"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/kick/clip", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await kick.clip(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

// -- Google extras (search + advertiser ads + single ad detail) ----------

social.get("/google-search", async (c) => {
  const user = c.get("user");
  const q = requireQuery(c, "q");
  if (!q) return c.json({ error: "missing_q" }, 400);
  const data = await googleExtras.search(c.env, q, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

social.get("/google-ads/advertiser/:advertiserId", async (c) => {
  const user = c.get("user");
  const data = await googleExtras.companyAds(c.env, c.req.param("advertiserId"), {
    tenant: user.id,
    ctx: c.executionCtx,
  });
  if (!data) return notFound(c);
  return c.json(data);
});

social.post("/google-ads/ad", async (c) => {
  const user = c.get("user");
  const body = (await c.req.json().catch(() => ({}))) as { url?: string };
  if (!body.url) return c.json({ error: "missing_url" }, 400);
  const data = await googleExtras.ad(c.env, body.url, { tenant: user.id, ctx: c.executionCtx });
  if (!data) return notFound(c);
  return c.json(data);
});

export default social;
