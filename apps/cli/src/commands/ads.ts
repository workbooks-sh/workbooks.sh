import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { VERBS } from "@brandnana/schema";
import type { AdSource } from "@brandnana/sdk";
import Database from "../sqlite.js";
import type { DbLike } from "../sqlite.js";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, progress, runAction } from "../output.js";
import { withSyncRun } from "../sync-runs.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

type SourceFlag = AdSource | "all" | "exa";

const ALLOWED_SOURCES: ReadonlyArray<SourceFlag> = [
  "meta",
  "tiktok",
  "google",
  "manual",
  "all",
  "exa",
];

function parseSource(v: string): SourceFlag {
  if ((ALLOWED_SOURCES as readonly string[]).includes(v)) {
    return v as SourceFlag;
  }
  throw new Error(`--source must be one of ${ALLOWED_SOURCES.join("|")} (got: ${v})`);
}

interface NormalisedAd {
  source: "meta" | "tiktok" | "google" | "manual";
  external_id: string;
  url: string | null;
  body: string | null;
  cta: string | null;
  first_seen_at: number;
  last_seen_at: number;
  raw_json: unknown;
}

const insertAdsSql = `
  INSERT INTO ads (
    id, brand_id, source, external_id, url, body, cta,
    first_seen_at, last_seen_at, raw_json
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(source, external_id) DO UPDATE SET
    url = excluded.url,
    body = excluded.body,
    cta = excluded.cta,
    last_seen_at = excluded.last_seen_at,
    raw_json = excluded.raw_json
`;

function upsertAds(db: DbLike, ads: NormalisedAd[], brandId: string | null): void {
  const insert = db.prepare(insertAdsSql);
  const insertMany = db.transaction((rows: NormalisedAd[]) => {
    for (const ad of rows) {
      insert.run(
        randomUUID(),
        brandId,
        ad.source,
        ad.external_id,
        ad.url,
        ad.body,
        ad.cta,
        ad.first_seen_at,
        ad.last_seen_at,
        JSON.stringify(ad.raw_json),
      );
    }
  });
  insertMany(ads);
}

// ── creative media mirroring (--mirror) ───────────────────────────────────────
//
// The substrate builder reads ad creative URLs from the `ad_media` table
// (SELECT ad_id, url FROM ad_media) and emits them as MEDIA_URL. It marks an ad
// STATUS=ok only when MEDIA_URL is a canonical R2 asset
// (https://api.brandnana.net/assets/<sha>); a raw vendor CDN URL (Meta/TikTok)
// fails the R2 shape check. So with --mirror we (1) extract every creative
// image/video URL from each ad's raw_json, (2) POST them to /mirror/images in
// batches, and (3) write the returned R2 URLs into ad_media keyed by the ad's
// SQLite id. Mirrors the catalog --mirror pattern (catalog.ts mirrorImageUrls).

const MIRROR_BATCH = 50;

// Creative-media URL keys seen across providers (Meta public library, Google
// transparency, TikTok, LinkedIn). Values may be strings or arrays of objects.
const MEDIA_URL_KEYS = new Set([
  "original_image_url",
  "resized_image_url",
  "image_url",
  "creative_image_url",
  "video_hd_url",
  "video_sd_url",
  "video_url",
  "video_preview_image_url",
  "thumbnail_url",
  "watermarked_video_url",
  "poster_url",
  "media_url",
  "cover",
]);

const MEDIA_EXT_RE = /\.(?:png|jpe?g|webp|gif|svg|mp4|webm|mov)(?:[?#]|$)/i;

/** Recursively pull creative image/video URLs out of an ad's raw_json. */
function extractMediaUrls(raw: unknown, out: Set<string>, depth = 0): void {
  if (depth > 8 || raw == null) return;
  if (typeof raw === "string") {
    if (/^https?:\/\//i.test(raw) && MEDIA_EXT_RE.test(raw)) out.add(raw);
    return;
  }
  if (Array.isArray(raw)) {
    for (const v of raw) extractMediaUrls(v, out, depth + 1);
    return;
  }
  if (typeof raw === "object") {
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
      if (MEDIA_URL_KEYS.has(k) && typeof v === "string" && /^https?:\/\//i.test(v)) {
        out.add(v);
      } else {
        extractMediaUrls(v, out, depth + 1);
      }
    }
  }
}

interface MediaPlan {
  adId: string; // SQLite ads.id
  kind: "image" | "video";
  rawUrl: string;
}

function kindForUrl(url: string): "image" | "video" {
  return /\.(?:mp4|webm|mov)(?:[?#]|$)/i.test(url) ? "video" : "image";
}

/**
 * After upsert, build the mirror plan from SQLite (so we have the real ads.id
 * for each external_id), mirror the URLs to R2, and write ad_media rows.
 */
async function mirrorAdCreatives(
  // biome-ignore lint/suspicious/noExplicitAny: SDK type would force a circular import
  client: any,
  db: DbLike,
  ads: NormalisedAd[],
): Promise<{ replaced: number; skipped: number; rows: number }> {
  // Resolve external_id → ads.id (upsert used randomUUID / ON CONFLICT).
  const getId = db.prepare("SELECT id FROM ads WHERE source = ? AND external_id = ?");
  const plan: MediaPlan[] = [];
  for (const ad of ads) {
    const row = getId.get(ad.source, ad.external_id) as { id: string } | undefined;
    if (!row) continue;
    const urls = new Set<string>();
    extractMediaUrls(ad.raw_json, urls);
    for (const u of urls) plan.push({ adId: row.id, kind: kindForUrl(u), rawUrl: u });
  }
  if (plan.length === 0) return { replaced: 0, skipped: 0, rows: 0 };

  // Mirror unique URLs in batches.
  const uniqueUrls = [...new Set(plan.map((p) => p.rawUrl))];
  const mapping: Record<string, string> = {};
  for (let i = 0; i < uniqueUrls.length; i += MIRROR_BATCH) {
    const batch = uniqueUrls.slice(i, i + MIRROR_BATCH);
    const result = (await client.mirror.images(batch)) as {
      mapping: Record<string, string>;
      skipped: string[];
    };
    Object.assign(mapping, result.mapping);
  }

  const insertMedia = db.prepare(
    `INSERT OR REPLACE INTO ad_media (id, ad_id, kind, url, poster_url, width, height)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  );
  let replaced = 0;
  let skipped = 0;
  let rows = 0;
  const tx = db.transaction((items: MediaPlan[]) => {
    for (const p of items) {
      const r2 = mapping[p.rawUrl];
      if (!r2) {
        skipped++;
        continue;
      }
      replaced++;
      insertMedia.run(randomUUID(), p.adId, p.kind, r2, null, null, null);
      rows++;
    }
  });
  tx(plan);
  return { replaced, skipped, rows };
}

export function registerAds(program: Command) {
  const ads = program.command("ads").description("Sync and query ad creatives");

  ads
    .command("sync")
    .description(verbSummary("ads.sync"))
    .option("--source <source>", "meta (only source implemented today)", "meta")
    .option("--ad-account-id <id>", "Specific Meta ad account (e.g. act_1234…). Omit to sync all")
    .option("--limit <n>", "Max ads per ad account", "50")
    .option("--db <path>", "SQLite path", ".brandnana/brandnana.sqlite")
    .option("--brand-id <uuid>", "Brand id to tag the ads with (FK into brands)")
    .option("--base-url <url>", "Override API base URL")
    .action(
      (opts: {
        source: string;
        adAccountId?: string;
        limit: string;
        db: string;
        brandId?: string;
        baseUrl?: string;
      }) =>
        runAction(async () => {
          const source = parseSource(opts.source);
          if (source !== "meta") {
            throw new Error("only --source=meta is implemented today");
          }
          const client = await clientFromEnv(opts.baseUrl);

          const accounts = opts.adAccountId
            ? [{ id: opts.adAccountId, account_id: opts.adAccountId.replace(/^act_/, "") }]
            : (await client.ads.meta.accounts()).accounts;

          if (accounts.length === 0) {
            throw new Error(
              "No Meta ad accounts. Run `brandnana auth meta` to connect a Meta account first.",
            );
          }

          const dbPath = resolve(process.cwd(), opts.db);
          const db = new Database(dbPath);
          db.pragma("foreign_keys = ON");

          const limit = Math.min(Math.max(Number.parseInt(opts.limit, 10) || 50, 1), 500);
          let totalAds = 0;
          try {
            await withSyncRun(db, { kind: "ads", source: "meta" }, async () => {
              for (const acct of accounts) {
                progress(`fetching ads for ${acct.id}${acct.name ? ` (${acct.name})` : ""}…`);
                const result = await client.ads.meta.fetch(acct.id, limit);
                upsertAds(db, result.ads, opts.brandId ?? null);
                totalAds += result.ads.length;
                progress(`  ${result.ads.length} ads from ${acct.id}`);
              }
            });
          } finally {
            db.close();
          }

          emit(
            { source: "meta", accounts: accounts.length, ads: totalAds, db: dbPath },
            `synced ${totalAds} ads from ${accounts.length} Meta ad account(s) → ${dbPath}`,
          );
        }),
    );

  ads
    .command("search <query>")
    .description(verbSummary("ads.search"))
    .option("--source <source>", "exa|meta|tiktok|google|all", "all")
    .option("--brand <domain>", "Brand to scope ad-library searches")
    .option("--limit <n>", "Max results", "50")
    .option("--db <path>", "SQLite path", ".brandnana/brandnana.sqlite")
    .option("--no-save", "Skip writing rows to the local SQLite")
    .option("--mirror", "Mirror each ad creative to R2 and write ad_media rows with canonical asset URLs")
    .option("--base-url <url>", "Override API base URL")
    .action(
      (
        query: string,
        opts: {
          source: string;
          brand?: string;
          limit: string;
          db: string;
          save: boolean;
          mirror?: boolean;
          baseUrl?: string;
        },
      ) =>
        runAction(async () => {
          const source = parseSource(opts.source);
          const client = await clientFromEnv(opts.baseUrl);
          const result = await client.ads.search({
            query,
            source,
            limit: Number.parseInt(opts.limit, 10),
            brand: opts.brand,
          });

          if (opts.save !== false) {
            const dbPath = resolve(process.cwd(), opts.db);
            const db = new Database(dbPath);
            db.pragma("foreign_keys = ON");
            let mirrorNote = "";
            try {
              await withSyncRun(db, { kind: "ads", source }, async () => {
                upsertAds(db, result.ads, null);
                // Mirror creative media to R2 + write ad_media so the substrate
                // builder renders MEDIA_URL as a canonical R2 asset (STATUS=ok),
                // not a raw vendor CDN hotlink.
                if (opts.mirror && result.ads.length > 0) {
                  progress(`mirroring ad creatives for ${result.ads.length} ad(s) to R2…`);
                  const { replaced, skipped, rows } = await mirrorAdCreatives(
                    client,
                    db,
                    result.ads,
                  );
                  mirrorNote = ` [mirrored ${rows} media: ${replaced} R2, ${skipped} skipped]`;
                  progress(`mirrored: ${replaced} R2 assets, ${skipped} skipped, ${rows} ad_media rows`);
                }
              });
            } finally {
              db.close();
            }
            emit(
              { ...result, mirrored: opts.mirror ?? false },
              `${result.count} ads (saved to ${dbPath})${mirrorNote}`,
            );
          } else {
            emit(result, JSON.stringify(result, null, 2));
          }
        }),
    );
}
