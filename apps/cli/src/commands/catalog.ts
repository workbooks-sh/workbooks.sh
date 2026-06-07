import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { VERBS } from "@brandnana/schema";
import { BrandnanaError, type CatalogCrawlStatus, type CatalogRow, type CatalogStrategy } from "@brandnana/sdk";
import Database from "../sqlite.js";
import type { DbLike } from "../sqlite.js";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, progress, runAction } from "../output.js";
import { withSyncRun } from "../sync-runs.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

const ALLOWED_STRATEGIES: ReadonlyArray<CatalogStrategy> = [
  "auto",
  "shopify",
  "context-dev",
  "sitemap",
  "llm",
];

function parseStrategy(v: string): CatalogStrategy {
  if ((ALLOWED_STRATEGIES as readonly string[]).includes(v)) {
    return v as CatalogStrategy;
  }
  throw new Error(`--strategy must be one of ${ALLOWED_STRATEGIES.join("|")} (got: ${v})`);
}

interface ActionOpts {
  strategy: string;
  brandId?: string;
  baseUrl?: string;
  db: string;
  maxUrls?: string;
  mirror?: boolean;
}

const MIRROR_BATCH = 50;

async function mirrorImageUrls(
  // biome-ignore lint/suspicious/noExplicitAny: SDK type would force a circular import
  client: any,
  db: DbLike,
  imageIds: string[],
): Promise<{ replaced: number; skipped: number }> {
  if (imageIds.length === 0) return { replaced: 0, skipped: 0 };
  const placeholders = imageIds.map(() => "?").join(",");
  const get = db.prepare(`SELECT id, url FROM product_images WHERE id IN (${placeholders})`);
  const rows = get.all(...imageIds) as Array<{ id: string; url: string }>;
  const update = db.prepare("UPDATE product_images SET url = ? WHERE id = ?");
  let replaced = 0;
  let skipped = 0;
  // Mirror in bounded-concurrency WAVES: the slow network/R2 work (each
  // client.mirror.images call) overlaps across a wave, while the SQLite writes
  // (single-writer) stay sequential after each wave. This is the catalog's
  // DOMINANT cost — ~98 sequential batches took 3.46m in scout run #6 (wb-syjo);
  // 8-wide waves bring it to ~30s. The cap keeps CDN/R2 in-flight load bounded.
  const MIRROR_CONCURRENCY = 8;
  const batches: { id: string; url: string }[][] = [];
  for (let i = 0; i < rows.length; i += MIRROR_BATCH) {
    batches.push(rows.slice(i, i + MIRROR_BATCH));
  }
  for (let i = 0; i < batches.length; i += MIRROR_CONCURRENCY) {
    const wave = batches.slice(i, i + MIRROR_CONCURRENCY);
    const results = await Promise.all(
      wave.map(async (batch) => ({
        batch,
        result: (await client.mirror.images(batch.map((r) => r.url))) as {
          mapping: Record<string, string>;
          skipped: string[];
        },
      })),
    );
    for (const { batch, result } of results) {
      for (const r of batch) {
        const mirrored = result.mapping[r.url];
        if (mirrored) {
          update.run(mirrored, r.id);
          replaced++;
        } else {
          skipped++;
        }
      }
    }
  }
  return { replaced, skipped };
}

export function registerCatalog(program: Command) {
  const catalog = program.command("catalog").description("Crawl a brand's product catalog");

  catalog
    .command("crawl <domain>")
    .description(verbSummary("catalog.crawl"))
    .option("--strategy <strategy>", "auto|shopify|context-dev|sitemap|llm", "auto")
    .option("--brand-id <uuid>", "Brand id (generated if omitted)")
    .option("--db <path>", "SQLite path", ".brandnana/brandnana.sqlite")
    .option("--max-urls <n>", "Cap for sitemap crawl")
    .option("--mirror", "Mirror each image to R2 and rewrite local URLs")
    .option("--base-url <url>", "Override API base URL")
    .action((domain: string, opts: ActionOpts) =>
      runAction(async () => {
        const strategy = parseStrategy(opts.strategy);
        const client = await clientFromEnv(opts.baseUrl);
        const dbPath = resolve(process.cwd(), opts.db);
        const db = new Database(dbPath);
        db.pragma("foreign_keys = ON");

        // Ensure a brands row exists for this domain so products can FK to it.
        // If --brand-id wasn't passed and a row already exists for the
        // domain, reuse that id (so re-crawls accumulate into the same brand).
        let brandId = opts.brandId;
        if (!brandId) {
          const existing = db.prepare("SELECT id FROM brands WHERE domain = ?").get(domain) as
            | { id: string }
            | undefined;
          brandId = existing?.id ?? randomUUID();
        }
        db.prepare(
          `INSERT INTO brands (id, domain, fetched_at)
           VALUES (?, ?, ?)
           ON CONFLICT(domain) DO NOTHING`,
        ).run(brandId, domain, Date.now());
        // Re-read brand_id in case the conflict path skipped our insert.
        const finalBrand = db.prepare("SELECT id FROM brands WHERE domain = ?").get(domain) as {
          id: string;
        };
        brandId = finalBrand.id;

        const insertProduct = db.prepare(
          `INSERT INTO products (
             id, brand_id, external_id, url, title, description, price_cents, currency,
             available, platform, raw_json, first_seen_at, last_seen_at
           ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(brand_id, url) DO UPDATE SET
             title = excluded.title,
             description = excluded.description,
             price_cents = excluded.price_cents,
             currency = excluded.currency,
             available = excluded.available,
             platform = excluded.platform,
             raw_json = excluded.raw_json,
             last_seen_at = excluded.last_seen_at`,
        );
        const insertImage = db.prepare(
          `INSERT OR REPLACE INTO product_images (
             id, product_id, url, alt, width, height, position
           ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
        );

        let products = 0;
        let images = 0;
        const mirroredImageIds: string[] = [];

        try {
          // Omit brand_id: the brands row may not exist yet (catalog crawl
          // doesn't write to brands; `brandnana brand fetch` does that).
          await withSyncRun(db, { kind: "catalog", source: strategy }, async () => {
            const stream = client.catalog.crawl({
              domain,
              strategy,
              brandId,
              maxUrls: opts.maxUrls ? Number.parseInt(opts.maxUrls, 10) : undefined,
            });

            for await (const row of stream as AsyncIterable<CatalogRow>) {
              if (row.__type === "product") {
                insertProduct.run(
                  row.id,
                  row.brand_id,
                  row.external_id,
                  row.url,
                  row.title,
                  row.description,
                  row.price_cents,
                  row.currency,
                  row.available,
                  row.platform,
                  row.raw_json,
                  row.first_seen_at,
                  row.last_seen_at,
                );
                products += 1;
                if (products % 50 === 0) {
                  progress(`… ${products} products, ${images} images`);
                }
              } else if (row.__type === "product_image") {
                insertImage.run(
                  row.id,
                  row.product_id,
                  row.url,
                  row.alt,
                  row.width,
                  row.height,
                  row.position,
                );
                images += 1;
                if (opts.mirror) mirroredImageIds.push(row.id);
              } else {
                progress(`stats: ${JSON.stringify(row)}`);
              }
            }
          });

          if (opts.mirror && mirroredImageIds.length > 0) {
            progress(`mirroring ${mirroredImageIds.length} images to R2…`);
            const { replaced, skipped } = await mirrorImageUrls(client, db, mirroredImageIds);
            progress(`mirrored: ${replaced} replaced, ${skipped} skipped`);
          }
        } catch (err) {
          // The crawl is async (a Durable Object): a SECOND invocation while one
          // is already running returns 409 crawl_in_progress (wb-tewy). Wait for
          // the in-flight crawl to finish so the agent doesn't retry-spin — then
          // exit LOUD. THIS invocation streamed nothing into local sqlite (and a
          // prior timeout-cut run may have left it partial); substrate build reads
          // local sqlite, so reporting success here would silently render a PARTIAL
          // catalog that passes substrate check. Force a clean re-run instead.
          if (!isCrawlInProgress(err)) throw err;
          const fin = await waitForCrawl(client, domain); // throws loud on fail/timeout
          throw new BrandnanaError(
            `a concurrent crawl just finished server-side (${fin.products ?? 0} products) but THIS run wrote nothing locally — re-run \`brandnana catalog crawl\` now (no crawl is running) to stream the full catalog into local sqlite.`,
            409,
          );
        } finally {
          db.close();
        }

        emit(
          { domain, brand_id: brandId, products, images, strategy, mirrored: opts.mirror ?? false },
          `crawl complete: ${products} products, ${images} images${opts.mirror ? " (mirrored)" : ""}`,
        );
      }),
    );
}

/** A 409 crawl_in_progress from the async crawl DO (vs any other error). */
function isCrawlInProgress(err: unknown): boolean {
  return (
    err instanceof BrandnanaError &&
    err.status === 409 &&
    (err.body as { error?: string } | undefined)?.error === "crawl_in_progress"
  );
}

/**
 * Poll GET /catalog/status/<domain> until the in-flight crawl is terminal.
 * Returns the finished status; throws LOUD on server-side failure or timeout
 * (so the caller exits non-zero instead of the old silent exit-0 spin).
 */
async function waitForCrawl(
  client: Awaited<ReturnType<typeof clientFromEnv>>,
  domain: string,
): Promise<CatalogCrawlStatus> {
  // MUST stay under the engine agent-bash timeout (WB_BASH_TIMEOUT_MS, default
  // 300_000) or the wait itself gets cut and the spin returns. Default 240s
  // (4 min) leaves a buffer; override with WB_CATALOG_WAIT_MS.
  const waitMs = Number.parseInt(process.env.WB_CATALOG_WAIT_MS ?? "", 10) || 240_000;
  const deadline = Date.now() + waitMs;
  progress("crawl already running server-side — waiting for it to finish…");
  while (Date.now() < deadline) {
    const s = await client.catalog.status(domain);
    if (s.status === "finished") return s;
    if (s.status === "failed") {
      throw new Error(`catalog crawl failed server-side: ${JSON.stringify(s.errors ?? [])}`);
    }
    progress(`… crawl ${s.status}: ${s.products ?? 0} products, ${s.images ?? 0} images`);
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error(`catalog crawl did not finish within ${Math.round(waitMs / 1000)}s — server crawl may be stuck`);
}
