// Shared social profile summarisers.
//
// Used by both /brief and the direct /social/<platform>/:handle routes so
// the shape is identical across surfaces. Each summarise* takes the raw
// vendor JSON and returns a normalized {username, followers, ...} shape
// — or null if the input doesn't look like a real profile response.

export interface ProfileSummary {
  platform: "instagram" | "tiktok" | "youtube" | "twitter" | "facebook";
  username: string | null;
  display_name: string | null;
  bio: string | null;
  followers: number | null;
  /** Posts / videos / tweets / channel uploads — whatever counts as "items". */
  posts: number | null;
  verified: boolean | null;
  /** Platform-specific extra fields agents tend to want. */
  extra: Record<string, unknown>;
}

export function summariseInstagram(ig: unknown): ProfileSummary | null {
  if (!ig || typeof ig !== "object") return null;
  const user = (ig as { data?: { user?: Record<string, unknown> } }).data?.user;
  if (!user) return null;
  return {
    platform: "instagram",
    username: (user.username as string) ?? null,
    display_name: (user.full_name as string) ?? null,
    bio: (user.biography as string) ?? null,
    followers: (user as { edge_followed_by?: { count?: number } }).edge_followed_by?.count ?? null,
    posts:
      (user as { edge_owner_to_timeline_media?: { count?: number } }).edge_owner_to_timeline_media
        ?.count ?? null,
    verified: (user.is_verified as boolean) ?? null,
    extra: {
      is_business: user.is_business_account,
      is_private: user.is_private,
      external_url: user.external_url,
      profile_pic_url: user.profile_pic_url_hd ?? user.profile_pic_url,
    },
  };
}

export function summariseTiktok(tt: unknown): ProfileSummary | null {
  if (!tt || typeof tt !== "object") return null;
  const user = (tt as { user?: Record<string, unknown> }).user;
  const stats = (tt as { stats?: Record<string, unknown> }).stats;
  if (!user) return null;
  return {
    platform: "tiktok",
    username: (user.uniqueId as string) ?? null,
    display_name: (user.nickname as string) ?? null,
    bio: (user.signature as string) ?? null,
    followers: (stats?.followerCount as number) ?? null,
    posts: (stats?.videoCount as number) ?? null,
    verified: (user.verified as boolean) ?? null,
    extra: {
      following: stats?.followingCount,
      hearts: stats?.heartCount,
      private: user.privateAccount,
      avatar: user.avatarMedium ?? user.avatarThumb,
    },
  };
}

export function summariseYoutube(yt: unknown): ProfileSummary | null {
  if (!yt || typeof yt !== "object") return null;
  const d = yt as Record<string, unknown>;
  if (!d.channelId) return null;
  return {
    platform: "youtube",
    username: typeof d.channel === "string" ? (d.channel.split("/@")[1] ?? null) : null,
    display_name: (d.title as string) ?? (d.channel as string) ?? null,
    bio: (d.description as string) ?? null,
    followers: (d.subscriberCount as number) ?? null,
    posts: (d.videoCount as number) ?? null,
    verified: null,
    extra: {
      channel_id: d.channelId,
      total_views: d.viewCount,
      subscriber_text: d.subscriberCountText,
    },
  };
}

export function summariseTwitter(tw: unknown): ProfileSummary | null {
  if (!tw || typeof tw !== "object") return null;
  const core = (tw as { core?: Record<string, unknown> }).core;
  const legacy = (tw as { legacy?: Record<string, unknown> }).legacy;
  if (!core && !legacy) return null;
  return {
    platform: "twitter",
    username: ((legacy?.screen_name ?? core?.screen_name) as string) ?? null,
    display_name: ((legacy?.name ?? core?.name) as string) ?? null,
    bio: (legacy?.description as string) ?? null,
    followers: (legacy?.followers_count as number) ?? null,
    posts: (legacy?.statuses_count as number) ?? null,
    verified: (legacy?.verified as boolean) ?? null,
    extra: {
      following: legacy?.friends_count,
      listed: legacy?.listed_count,
      created_at: legacy?.created_at,
    },
  };
}

export function summariseFacebook(fb: unknown): ProfileSummary | null {
  if (!fb || typeof fb !== "object") return null;
  const d = fb as Record<string, unknown>;
  if (!d.name) return null;
  return {
    platform: "facebook",
    username: (d.id as string) ?? null,
    display_name: (d.name as string) ?? null,
    bio: (d.about as string) ?? null,
    followers: (d.followers as number) ?? (d.likes as number) ?? null,
    posts: null,
    verified: (d.verified as boolean) ?? null,
    extra: {
      page_id: d.id,
      category: d.category,
      creation_date: d.creationDate,
    },
  };
}
