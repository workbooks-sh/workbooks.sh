// Social-data wrapper — the rich endpoint surface beyond the
// ad-library subset already in scrapecreators.ts.
//
// Upstream is Scrapecreators today; we keep all wire-level details in
// this file so the rest of the codebase, the SDK, and end users only
// see `brandnana social …` and `provider: "social-data"`.
//
// Route table is intentionally explicit (vs a passthrough proxy) so
// our URL space stays stable even if the upstream path schema changes.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";

const BASE = "https://api.scrapecreators.com";

interface SocialOptions {
  tenant: string;
  ctx?: ExecutionContext;
}

async function get<T>(
  env: Bindings,
  path: string,
  query: Record<string, string | undefined>,
  opts: SocialOptions,
  cacheTtl = 1800,
): Promise<T | null> {
  if (!env.SCRAPECREATORS_API_KEY) return null;
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(query)) {
    if (v !== undefined && v !== "") url.searchParams.set(k, v);
  }
  const res = await vendorFetch(env, {
    provider: "social-data",
    tenant: opts.tenant,
    url: url.toString(),
    method: "GET",
    headers: { "x-api-key": env.SCRAPECREATORS_API_KEY },
    cacheTtl,
    rateLimit: 30,
    metadata: { route: path },
    ctx: opts.ctx,
  });
  if (!res.ok) return null;
  try {
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

// -- Instagram ------------------------------------------------------------

export const instagram = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/instagram/profile", { handle }, opts, 86_400),
  basicProfile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/instagram/basic-profile", { handle }, opts, 86_400),
  userPosts: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v2/instagram/user/posts", { handle }, opts, 1800),
  userReels: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/instagram/user/reels", { handle }, opts, 1800),
  userHighlights: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/instagram/user/highlights", { handle }, opts, 3600),
  post: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/instagram/post", { url }, opts, 86_400),
  postComments: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v2/instagram/post/comments", { url }, opts, 1800),
  reelsSearch: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v2/instagram/reels/search", { query }, opts, 1800),
  mediaTranscript: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v2/instagram/media/transcript", { url }, opts, 86_400),
};

// -- Facebook Marketplace + Events --------------------------------------

export const facebookMarketplace = {
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/marketplace/search", { query }, opts, 1800),
  item: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/marketplace/item", { url }, opts, 3600),
};

export const facebookEvents = {
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/events/search", { query }, opts, 1800),
  details: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/event/details", { url }, opts, 3600),
};

// -- TikTok ---------------------------------------------------------------

export const tiktok = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/profile", { handle }, opts, 86_400),
  profileVideos: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v3/tiktok/profile/videos", { handle }, opts, 3600),
  video: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v2/tiktok/video", { url }, opts, 86_400),
  videoComments: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/video/comments", { url }, opts, 1800),
  videoTranscript: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/video/transcript", { url }, opts, 86_400),
  userFollowers: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/user/followers", { handle }, opts, 3600),
  userFollowing: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/user/following", { handle }, opts, 3600),
  userLive: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/user/live", { handle }, opts, 300),
  searchUsers: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/search/users", { query }, opts, 1800),
  searchHashtag: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/search/hashtag", { query }, opts, 1800),
  searchKeyword: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/search/keyword", { query }, opts, 1800),
  searchTop: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/search/top", { query }, opts, 1800),
  popularCreators: (env: Bindings, opts: SocialOptions) =>
    get(env, "/v1/tiktok/creators/popular", {}, opts, 3600),
  popularHashtags: (env: Bindings, opts: SocialOptions) =>
    get(env, "/v1/tiktok/hashtags/popular", {}, opts, 3600),
  trendingFeed: (env: Bindings, opts: SocialOptions) =>
    get(env, "/v1/tiktok/get-trending-feed", {}, opts, 600),
  song: (env: Bindings, id: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/song", { id }, opts, 86_400),
  songVideos: (env: Bindings, id: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/song/videos", { id }, opts, 1800),
};

// -- LinkedIn -------------------------------------------------------------

export const linkedin = {
  adSearch: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/linkedin/ads/search", { query }, opts, 1800),
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/linkedin/profile", { handle }, opts, 86_400),
  company: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/linkedin/company", { handle }, opts, 86_400),
  companyPosts: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/linkedin/company/posts", { handle }, opts, 3600),
  post: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/linkedin/post", { url }, opts, 86_400),
};

// -- YouTube --------------------------------------------------------------

export const youtube = {
  channel: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/channel", { handle }, opts, 86_400),
  channelVideos: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/channel-videos", { handle }, opts, 3600),
  channelShorts: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/channel/shorts", { handle }, opts, 3600),
  video: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/video", { url }, opts, 86_400),
  videoTranscript: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/video/transcript", { url }, opts, 86_400),
  videoComments: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/video/comments", { url }, opts, 1800),
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/search", { query }, opts, 1800),
  searchHashtag: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/search/hashtag", { query }, opts, 1800),
  shortsTrending: (env: Bindings, opts: SocialOptions) =>
    get(env, "/v1/youtube/shorts/trending", {}, opts, 600),
  playlist: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/youtube/playlist", { url }, opts, 86_400),
};

// -- Twitter / X ----------------------------------------------------------

export const twitter = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/twitter/profile", { handle }, opts, 86_400),
  userTweets: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/twitter/user-tweets", { handle }, opts, 1800),
  tweet: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/twitter/tweet", { url }, opts, 86_400),
  tweetTranscript: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/twitter/tweet/transcript", { url }, opts, 86_400),
};

// -- Facebook (profile / posts, NOT ads — those go through ads-library) ----
// Facebook wraps take handles for ergonomics but the upstream wants the
// full facebook.com URL — we synthesize one if the caller passes a bare
// handle.

function fbProfileUrl(handle: string): string {
  if (/^https?:\/\//i.test(handle)) return handle;
  return `https://www.facebook.com/${handle.replace(/^@/, "")}`;
}

export const facebook = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/profile", { url: fbProfileUrl(handle) }, opts, 86_400),
  profilePosts: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/profile/posts", { url: fbProfileUrl(handle) }, opts, 3600),
  profileReels: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/profile/reels", { url: fbProfileUrl(handle) }, opts, 3600),
  profilePhotos: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/profile/photos", { url: fbProfileUrl(handle) }, opts, 3600),
  post: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/post", { url }, opts, 86_400),
  postComments: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/facebook/post/comments", { url }, opts, 1800),
};

// -- TikTok Shop (commerce) ----------------------------------------------

export const tiktokShop = {
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/shop/search", { query }, opts, 3600),
  shopProducts: (env: Bindings, shopId: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/shop/products", { shop_id: shopId }, opts, 3600),
  product: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/product", { url }, opts, 86_400),
  productReviews: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/shop/product/reviews", { url }, opts, 3600),
  userShowcase: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/tiktok/user/showcase", { handle }, opts, 3600),
};

// -- Threads --------------------------------------------------------------

export const threads = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/threads/profile", { handle }, opts, 86_400),
  userPosts: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/threads/user/posts", { handle }, opts, 1800),
  post: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/threads/post", { url }, opts, 86_400),
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/threads/search", { query }, opts, 1800),
  searchUsers: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/threads/search/users", { query }, opts, 1800),
};

// -- Link aggregators (linktree etc — useful for cross-channel discovery) -
// Each platform wants a full URL; we synthesize one from a bare handle.

function urlFor(host: string, handleOrUrl: string): string {
  if (/^https?:\/\//i.test(handleOrUrl)) return handleOrUrl;
  return `https://${host}/${handleOrUrl.replace(/^@/, "")}`;
}

export const linktree = {
  fetch: (env: Bindings, handleOrUrl: string, opts: SocialOptions) =>
    get(env, "/v1/linktree", { url: urlFor("linktr.ee", handleOrUrl) }, opts, 86_400),
};

export const komi = {
  fetch: (env: Bindings, handleOrUrl: string, opts: SocialOptions) =>
    get(env, "/v1/komi", { url: urlFor("komi.io", handleOrUrl) }, opts, 86_400),
};

export const pillar = {
  fetch: (env: Bindings, handleOrUrl: string, opts: SocialOptions) =>
    get(env, "/v1/pillar", { url: urlFor("pillar.io", handleOrUrl) }, opts, 86_400),
};

export const linkbio = {
  fetch: (env: Bindings, handleOrUrl: string, opts: SocialOptions) =>
    get(env, "/v1/linkbio", { url: urlFor("link.bio", handleOrUrl) }, opts, 86_400),
};

export const linkme = {
  fetch: (env: Bindings, handleOrUrl: string, opts: SocialOptions) =>
    get(env, "/v1/linkme", { url: urlFor("linkme.bio", handleOrUrl) }, opts, 86_400),
};

// -- Bluesky --------------------------------------------------------------

export const bluesky = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/bluesky/profile", { handle }, opts, 86_400),
  userPosts: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/bluesky/user/posts", { handle }, opts, 1800),
  post: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/bluesky/post", { url }, opts, 86_400),
};

// -- Twitch ---------------------------------------------------------------

export const twitch = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/twitch/profile", { handle }, opts, 86_400),
  userVideos: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/twitch/user/videos", { handle }, opts, 3600),
  userSchedule: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/twitch/user/schedule", { handle }, opts, 3600),
  clip: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/twitch/clip", { url }, opts, 86_400),
};

// -- Spotify --------------------------------------------------------------

export const spotify = {
  artist: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/spotify/artist", { url }, opts, 86_400),
  track: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/spotify/track", { url }, opts, 86_400),
  album: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/spotify/album", { url }, opts, 86_400),
};

// -- Pinterest ------------------------------------------------------------

export const pinterest = {
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/pinterest/search", { query }, opts, 3600),
  pin: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/pinterest/pin", { url }, opts, 86_400),
  userBoards: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/pinterest/user/boards", { handle }, opts, 3600),
  board: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/pinterest/board", { url }, opts, 3600),
};

// -- Rumble --------------------------------------------------------------

export const rumble = {
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/rumble/search", { query }, opts, 1800),
  channelVideos: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/rumble/channel/videos", { handle }, opts, 1800),
  video: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/rumble/video", { url }, opts, 86_400),
  videoTranscript: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/rumble/video/transcript", { url }, opts, 86_400),
};

// -- SoundCloud ----------------------------------------------------------

export const soundcloud = {
  artist: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/soundcloud/artist", { url }, opts, 86_400),
  artistTracks: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/soundcloud/artist/tracks", { url }, opts, 1800),
  track: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/soundcloud/track", { url }, opts, 86_400),
};

// -- Truth Social --------------------------------------------------------

export const truthsocial = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/truthsocial/profile", { handle }, opts, 86_400),
  userPosts: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/truthsocial/user/posts", { handle }, opts, 1800),
  post: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/truthsocial/post", { url }, opts, 86_400),
};

// -- Snapchat / Kick (single-endpoint platforms) -------------------------

export const snapchat = {
  profile: (env: Bindings, handle: string, opts: SocialOptions) =>
    get(env, "/v1/snapchat/profile", { handle }, opts, 86_400),
};

export const kick = {
  clip: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/kick/clip", { url }, opts, 86_400),
};

// -- Google extras (search + ad detail) ---------------------------------

export const googleExtras = {
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/google/search", { query }, opts, 1800),
  companyAds: (env: Bindings, advertiserId: string, opts: SocialOptions) =>
    get(env, "/v1/google/company/ads", { advertiser_id: advertiserId }, opts, 3600),
  ad: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/google/ad", { url }, opts, 86_400),
};

// -- Reddit ---------------------------------------------------------------
// Upstream wants `subreddit=` param (not `name=`).

export const reddit = {
  subreddit: (env: Bindings, subreddit: string, opts: SocialOptions) =>
    get(env, "/v1/reddit/subreddit", { subreddit }, opts, 3600),
  subredditDetails: (env: Bindings, subreddit: string, opts: SocialOptions) =>
    get(env, "/v1/reddit/subreddit/details", { subreddit }, opts, 86_400),
  subredditSearch: (env: Bindings, subreddit: string, query: string, opts: SocialOptions) =>
    get(env, "/v1/reddit/subreddit/search", { subreddit, query }, opts, 1800),
  postComments: (env: Bindings, url: string, opts: SocialOptions) =>
    get(env, "/v1/reddit/post/comments", { url }, opts, 1800),
  search: (env: Bindings, query: string, opts: SocialOptions) =>
    get(env, "/v1/reddit/search", { query }, opts, 1800),
};
