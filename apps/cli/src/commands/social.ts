// `brandnana social …` — surfaces the social-data backend across 7
// platforms: Instagram, TikTok, YouTube, Twitter/X, Facebook, Reddit,
// LinkedIn. Output is the raw vendor JSON (printed pretty in human
// mode, compact in --json). The agent / user can drill in via jq or
// similar.

import { VERBS } from "@brandnana/schema";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, runAction } from "../output.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

function print(result: unknown): void {
  emit(result, JSON.stringify(result, null, 2));
}

export function registerSocial(program: Command) {
  const social = program
    .command("social")
    .description(
      "Cross-platform creator + content lookups (Instagram, TikTok, YouTube, Twitter/X, Facebook, Reddit, LinkedIn)",
    );

  // -- Instagram ---------------------------------------------------------

  const ig = social.command("instagram").description("Instagram lookups");
  ig.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.instagram.profile(handle));
      }),
    );
  for (const kind of ["posts", "reels", "highlights"] as const) {
    ig.command(`${kind} <handle>`)
      .option("--base-url <url>")
      .action((handle: string, opts: { baseUrl?: string }) =>
        runAction(async () => {
          const client = await clientFromEnv(opts.baseUrl);
          const fn = (
            client.social.instagram as unknown as Record<string, (h: string) => Promise<unknown>>
          )[kind];
          if (typeof fn !== "function") throw new Error(`unknown instagram kind: ${kind}`);
          print(await fn.call(client.social.instagram, handle));
        }),
      );
  }
  ig.command("post <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.instagram.post(url));
      }),
    );
  ig.command("comments <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.instagram.postComments(url));
      }),
    );
  ig.command("transcript <url>")
    .description(verbSummary("social.instagram.transcript"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.instagram.mediaTranscript(url));
      }),
    );
  ig.command("reels-search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.instagram.reelsSearch(q));
      }),
    );

  // -- TikTok ------------------------------------------------------------

  const tt = social.command("tiktok").description("TikTok lookups");

  tt.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktok.profile(handle));
      }),
    );

  tt.command("videos <handle>")
    .description(verbSummary("social.tiktok.videos"))
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktok.videos(handle));
      }),
    );

  for (const which of ["followers", "following", "live"] as const) {
    tt.command(`${which} <handle>`)
      .option("--base-url <url>")
      .action((handle: string, opts: { baseUrl?: string }) =>
        runAction(async () => {
          const client = await clientFromEnv(opts.baseUrl);
          print(await client.social.tiktok[which](handle));
        }),
      );
  }

  tt.command("video <url>")
    .description(verbSummary("social.tiktok.video"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktok.video(url));
      }),
    );

  tt.command("comments <url>")
    .description(verbSummary("social.tiktok.comments"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktok.videoComments(url));
      }),
    );

  tt.command("transcript <url>")
    .description(verbSummary("social.tiktok.transcript"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktok.videoTranscript(url));
      }),
    );

  const search = tt.command("search").description("TikTok search");
  for (const kind of ["users", "hashtag", "keyword", "top"] as const) {
    const method = `search${kind[0]?.toUpperCase()}${kind.slice(1)}` as const;
    search
      .command(`${kind} <query>`)
      .option("--base-url <url>")
      .action((q: string, opts: { baseUrl?: string }) =>
        runAction(async () => {
          const client = await clientFromEnv(opts.baseUrl);
          const fn = (
            client.social.tiktok as unknown as Record<string, (q: string) => Promise<unknown>>
          )[method];
          if (typeof fn !== "function") throw new Error(`unknown search kind: ${kind}`);
          print(await fn.call(client.social.tiktok, q));
        }),
      );
  }

  const trending = tt.command("trending").description("Trending creators / hashtags / feed");
  for (const which of ["creators", "hashtags", "feed"] as const) {
    const method = `trending${which[0]?.toUpperCase()}${which.slice(1)}` as const;
    trending
      .command(which)
      .option("--base-url <url>")
      .action((opts: { baseUrl?: string }) =>
        runAction(async () => {
          const client = await clientFromEnv(opts.baseUrl);
          const fn = (client.social.tiktok as unknown as Record<string, () => Promise<unknown>>)[
            method
          ];
          if (typeof fn !== "function") throw new Error(`unknown trending kind: ${which}`);
          print(await fn.call(client.social.tiktok));
        }),
      );
  }

  const song = tt.command("song <id>").description(verbSummary("social.tiktok.song"));
  song.option("--base-url <url>");
  song.action((id: string, opts: { baseUrl?: string }) =>
    runAction(async () => {
      const client = await clientFromEnv(opts.baseUrl);
      print(await client.social.tiktok.song(id));
    }),
  );

  tt.command("song-videos <id>")
    .description(verbSummary("social.tiktok.songVideos"))
    .option("--base-url <url>")
    .action((id: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktok.songVideos(id));
      }),
    );

  // -- LinkedIn ----------------------------------------------------------

  const li = social.command("linkedin").description("LinkedIn lookups");
  li.command("ads <query>")
    .description(verbSummary("social.linkedin.ads"))
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.linkedin.ads(q));
      }),
    );
  li.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.linkedin.profile(handle));
      }),
    );
  li.command("company <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.linkedin.company(handle));
      }),
    );
  li.command("posts <handle>")
    .description(verbSummary("social.linkedin.companyPosts"))
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.linkedin.companyPosts(handle));
      }),
    );

  // -- YouTube -----------------------------------------------------------

  const yt = social.command("youtube").description("YouTube lookups");
  yt.command("channel <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.youtube.channel(handle));
      }),
    );
  yt.command("videos <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.youtube.videos(handle));
      }),
    );
  yt.command("shorts <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.youtube.shorts(handle));
      }),
    );
  yt.command("video <url>")
    .description(verbSummary("social.youtube.video"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.youtube.video(url));
      }),
    );
  yt.command("transcript <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.youtube.videoTranscript(url));
      }),
    );
  yt.command("comments <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.youtube.videoComments(url));
      }),
    );
  yt.command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.youtube.search(q));
      }),
    );

  // -- Twitter / X -------------------------------------------------------

  const tw = social.command("twitter").description("Twitter / X lookups");
  tw.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.twitter.profile(handle));
      }),
    );
  tw.command("tweets <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.twitter.tweets(handle));
      }),
    );
  tw.command("tweet <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.twitter.tweet(url));
      }),
    );

  // -- Facebook ----------------------------------------------------------

  const fb = social.command("facebook").description("Facebook profile + posts");
  fb.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.facebook.profile(handle));
      }),
    );
  for (const kind of ["posts", "reels", "photos"] as const) {
    fb.command(`${kind} <handle>`)
      .option("--base-url <url>")
      .action((handle: string, opts: { baseUrl?: string }) =>
        runAction(async () => {
          const client = await clientFromEnv(opts.baseUrl);
          const fn = (
            client.social.facebook as unknown as Record<string, (h: string) => Promise<unknown>>
          )[kind];
          if (typeof fn !== "function") throw new Error(`unknown facebook kind: ${kind}`);
          print(await fn.call(client.social.facebook, handle));
        }),
      );
  }
  fb.command("post <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.facebook.post(url));
      }),
    );

  // -- Reddit ------------------------------------------------------------

  const rd = social.command("reddit").description("Reddit subreddit + search");
  rd.command("subreddit <name>")
    .option("--base-url <url>")
    .action((name: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.reddit.subreddit(name));
      }),
    );
  rd.command("details <name>")
    .option("--base-url <url>")
    .action((name: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.reddit.subredditDetails(name));
      }),
    );
  rd.command("search <query>")
    .description(verbSummary("social.reddit.search"))
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.reddit.search(q));
      }),
    );
  rd.command("subreddit-search <name> <query>")
    .description(verbSummary("social.reddit.subredditSearch"))
    .option("--base-url <url>")
    .action((name: string, q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.reddit.subredditSearch(name, q));
      }),
    );

  // -- TikTok Shop -------------------------------------------------------

  const shop = social.command("tiktok-shop").description("TikTok Shop commerce data");
  shop
    .command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktokShop.search(q));
      }),
    );
  shop
    .command("products <shop-id>")
    .option("--base-url <url>")
    .action((shopId: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktokShop.shopProducts(shopId));
      }),
    );
  shop
    .command("product <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktokShop.product(url));
      }),
    );
  shop
    .command("reviews <url>")
    .description(verbSummary("social.tiktokShop.productReviews"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktokShop.productReviews(url));
      }),
    );
  shop
    .command("showcase <handle>")
    .description(verbSummary("social.tiktokShop.showcase"))
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.tiktokShop.showcase(handle));
      }),
    );

  // -- Threads -----------------------------------------------------------

  const th = social.command("threads").description("Threads (Meta) profile + posts");
  th.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.threads.profile(handle));
      }),
    );
  th.command("posts <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.threads.posts(handle));
      }),
    );
  th.command("post <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.threads.post(url));
      }),
    );
  th.command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.threads.search(q));
      }),
    );

  // -- Pinterest ---------------------------------------------------------

  const pin = social.command("pinterest").description("Pinterest search + pins + boards");
  pin
    .command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.pinterest.search(q));
      }),
    );
  pin
    .command("boards <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.pinterest.boards(handle));
      }),
    );
  pin
    .command("pin <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.pinterest.pin(url));
      }),
    );
  pin
    .command("board <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.pinterest.board(url));
      }),
    );

  // -- Link aggregators --------------------------------------------------

  social
    .command("links <platform> <handle>")
    .description(verbSummary("social.links.fetch"))
    .option("--base-url <url>")
    .action((platform: string, handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const allowed = ["linktree", "komi", "pillar", "linkbio", "linkme"] as const;
        if (!(allowed as readonly string[]).includes(platform)) {
          throw new Error(`platform must be one of: ${allowed.join(", ")}`);
        }
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.links.fetch(platform as (typeof allowed)[number], handle));
      }),
    );

  // -- Bluesky -----------------------------------------------------------

  const bs = social.command("bluesky").description("Bluesky profile + posts");
  bs.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.bluesky.profile(handle));
      }),
    );
  bs.command("posts <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.bluesky.posts(handle));
      }),
    );
  bs.command("post <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.bluesky.post(url));
      }),
    );

  // -- Twitch ------------------------------------------------------------

  const tw2 = social.command("twitch").description("Twitch streamer + clips");
  tw2
    .command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.twitch.profile(handle));
      }),
    );
  tw2
    .command("videos <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.twitch.videos(handle));
      }),
    );
  tw2
    .command("schedule <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.twitch.schedule(handle));
      }),
    );
  tw2
    .command("clip <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.twitch.clip(url));
      }),
    );

  // -- Facebook Marketplace ----------------------------------------------

  const fbmp = social.command("facebook-marketplace").description("Facebook Marketplace listings");
  fbmp
    .command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.facebookMarketplace.search(q));
      }),
    );
  fbmp
    .command("item <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.facebookMarketplace.item(url));
      }),
    );

  // -- Facebook Events ---------------------------------------------------

  const fbev = social.command("facebook-events").description("Facebook events search + details");
  fbev
    .command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.facebookEvents.search(q));
      }),
    );
  fbev
    .command("details <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.facebookEvents.details(url));
      }),
    );

  // -- Rumble ------------------------------------------------------------

  const ru = social.command("rumble").description("Rumble video platform");
  ru.command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.rumble.search(q));
      }),
    );
  ru.command("videos <handle>")
    .description(verbSummary("social.rumble.channelVideos"))
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.rumble.channelVideos(handle));
      }),
    );
  ru.command("video <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.rumble.video(url));
      }),
    );
  ru.command("transcript <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.rumble.videoTranscript(url));
      }),
    );

  // -- SoundCloud --------------------------------------------------------

  const sc = social.command("soundcloud").description("SoundCloud artist + tracks");
  sc.command("artist <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.soundcloud.artist(url));
      }),
    );
  sc.command("tracks <url>")
    .description(verbSummary("social.soundcloud.artistTracks"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.soundcloud.artistTracks(url));
      }),
    );
  sc.command("track <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.soundcloud.track(url));
      }),
    );

  // -- Truth Social ------------------------------------------------------

  const ts = social.command("truthsocial").description("Truth Social profile + posts");
  ts.command("profile <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.truthsocial.profile(handle));
      }),
    );
  ts.command("posts <handle>")
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.truthsocial.posts(handle));
      }),
    );
  ts.command("post <url>")
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.truthsocial.post(url));
      }),
    );

  // -- Snapchat / Kick ---------------------------------------------------

  social
    .command("snapchat <handle>")
    .description(verbSummary("social.snapchat.profile"))
    .option("--base-url <url>")
    .action((handle: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.snapchat.profile(handle));
      }),
    );

  social
    .command("kick-clip <url>")
    .description(verbSummary("social.kick.clip"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.kick.clip(url));
      }),
    );

  // -- Google extras (search + advertiser ads + ad detail) ---------------

  const ge = social.command("google").description("Google search + ad detail");
  ge.command("search <query>")
    .option("--base-url <url>")
    .action((q: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.googleExtras.search(q));
      }),
    );
  ge.command("advertiser-ads <advertiserId>")
    .description(verbSummary("social.google.advertiserAds"))
    .option("--base-url <url>")
    .action((id: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.googleExtras.advertiserAds(id));
      }),
    );
  ge.command("ad <url>")
    .description(verbSummary("social.google.ad"))
    .option("--base-url <url>")
    .action((url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        print(await client.social.googleExtras.ad(url));
      }),
    );

  // -- Spotify -----------------------------------------------------------

  const sp = social.command("spotify").description("Spotify artist / track / album");
  for (const kind of ["artist", "track", "album"] as const) {
    sp.command(`${kind} <url>`)
      .option("--base-url <url>")
      .action((url: string, opts: { baseUrl?: string }) =>
        runAction(async () => {
          const client = await clientFromEnv(opts.baseUrl);
          const fn = (
            client.social.spotify as unknown as Record<string, (u: string) => Promise<unknown>>
          )[kind];
          if (typeof fn !== "function") throw new Error(`unknown spotify kind: ${kind}`);
          print(await fn.call(client.social.spotify, url));
        }),
      );
  }
}
