import { resolve } from "node:path";
import { VERBS } from "@brandnana/schema";
import Database from "../sqlite.js";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, runAction, say } from "../output.js";
import { withSyncRun } from "../sync-runs.js";
import { extractBrandFonts } from "./brand-fonts.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

export function registerBrand(program: Command) {
  const brand = program.command("brand").description("Fetch brand identity");

  brand
    .command("fetch <domain>")
    .description(verbSummary("brand.fetch"))
    .option("--db <path>", "SQLite path", ".brandnana/brandnana.sqlite")
    .option("--no-save", "Skip writing to local SQLite")
    .option("--base-url <url>", "Override API base URL")
    .option(
      "--minimal",
      "Skip fonts/screenshot/styleguide side-fetches (cheaper, faster)",
      false,
    )
    .option(
      "--include <list>",
      "Comma-separated extras: fonts,screenshot,styleguide,all (default: fonts,screenshot)",
    )
    .option(
      "--mirror",
      "Mirror the homepage screenshot to R2 and rewrite extras.screenshot_url to the canonical api.brandnana.net asset",
    )
    .action(
      (
        domain: string,
        opts: {
          db: string;
          save: boolean;
          baseUrl?: string;
          minimal: boolean;
          include?: string;
          mirror?: boolean;
        },
      ) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        // Default to fetching fonts + screenshot — that's what the
        // director actually needs to render branded scenes. Override
        // with --include or --minimal.
        let include: Array<"fonts" | "styleguide" | "screenshot" | "all"> = opts.minimal
          ? []
          : ["fonts", "screenshot"];
        if (opts.include) {
          include = opts.include
            .split(",")
            .map((s) => s.trim().toLowerCase())
            .filter((s): s is "fonts" | "styleguide" | "screenshot" | "all" =>
              s === "fonts" || s === "styleguide" || s === "screenshot" || s === "all",
            );
        }
        const result = await client.brand.fetch(domain, { include });
        const b = result.brand;

        // Mirror the screenshot singleton to R2 so the gathered raw/brand.json
        // carries a canonical api.brandnana.net asset URL. Without this the
        // builder reads extras.screenshot_url verbatim (a context.dev
        // media.brand.dev cache URL) and marks SCREENSHOT_URL STATUS=failed. The
        // returned R2 URL is written back into extras.screenshot_url in place.
        // Best-effort: if the mirror skips the URL, the raw value is left so the
        // builder renders needs_mirror rather than a green hotlink.
        if (opts.mirror && result.extras?.screenshot_url) {
          const shot = result.extras.screenshot_url;
          try {
            const mirror = await client.mirror.images([shot]);
            const r2 = mirror.mapping[shot];
            if (r2) {
              result.extras.screenshot_url = r2;
            } else {
              say(`screenshot not mirrored (skipped by /mirror/images): ${shot}`);
            }
          } catch (e) {
            say(`screenshot mirror failed: ${(e as Error).message}`);
          }
        }

        if (opts.save !== false) {
          const dbPath = resolve(process.cwd(), opts.db);
          const db = new Database(dbPath);
          db.pragma("foreign_keys = ON");
          try {
            // sync_runs.brand_id is FK-enforced; we omit it here because the
            // brands row doesn't exist yet at this point.
            await withSyncRun(db, { kind: "brand", source: "context-dev" }, async () => {
              db.prepare(
                `INSERT INTO brands (
                   id, domain, name, logo_url, palette_json, descriptors_json, fetched_at
                 ) VALUES (?, ?, ?, ?, ?, ?, ?)
                 ON CONFLICT(domain) DO UPDATE SET
                   name = excluded.name,
                   logo_url = excluded.logo_url,
                   palette_json = excluded.palette_json,
                   descriptors_json = excluded.descriptors_json,
                   fetched_at = excluded.fetched_at`,
              ).run(
                b.id,
                b.domain,
                b.name,
                b.logo_url,
                b.palette_json,
                b.descriptors_json,
                b.fetched_at,
              );
            });
          } finally {
            db.close();
          }
          const extrasSummary = result.extras
            ? ` [+${[
                result.extras.fonts ? `${result.extras.fonts.length} fonts` : null,
                result.extras.screenshot_url ? "screenshot" : null,
                result.extras.styleguide ? "styleguide" : null,
              ]
                .filter(Boolean)
                .join(", ")}]`
            : "";
          emit(
            result,
            `${domain}: ${b.name ?? "(no title)"} saved to ${dbPath}${extrasSummary}`,
          );
        } else {
          emit(result, JSON.stringify(result, null, 2));
        }
      }),
    );

  brand
    .command("product <domain> <url>")
    .description(verbSummary("brand.product"))
    .option("--base-url <url>", "Override API base URL")
    .action((domain: string, url: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        const result = await client.brand.product(domain, url);
        const p = result.product;
        if (!p) {
          emit(result, `product: ${url} — not found`);
          return;
        }
        const lines: string[] = [`product: ${p.name ?? "(no name)"}`];
        if (p.price?.amount) {
          lines.push(`  price: ${p.price.amount} ${p.price.currency ?? ""}`.trim());
        }
        if (p.images?.length) lines.push(`  images: ${p.images.length}`);
        if (p.features?.length) lines.push(`  features: ${p.features.length}`);
        emit(result, lines.join("\n"));
      }),
    );

  brand
    .command("fonts <domain>")
    .description(verbSummary("brand.fonts"))
    .option("--base-url <url>", "Override API base URL (used for WAF-bypass fallback)")
    .action((domain: string, opts: { baseUrl?: string }) =>
      runAction(async () => {
        say(`Extracting fonts for ${domain}…`);
        const result = await extractBrandFonts(domain, { baseUrl: opts.baseUrl });
        const summary = formatFontResultForHuman(result);
        emit(result, summary);
      }),
    );
}

function formatFontResultForHuman(result: {
  domain: string;
  primary_font: {
    family: string;
    weights: number[];
    italic_supported: boolean;
    source: string;
    files?: string[];
  } | null;
  secondary_font: {
    family: string;
    weights: number[];
    italic_supported: boolean;
    source: string;
  } | null;
  stack_css: string | null;
  headings_stack_css: string | null;
  body_stack_css: string | null;
  found_at: string[];
  error?: string;
}): string {
  if (result.error) {
    return `fonts: ${result.domain} — ${result.error}`;
  }
  const lines: string[] = [`fonts: ${result.domain}`];
  if (result.primary_font) {
    const pf = result.primary_font;
    lines.push(
      `  primary: ${pf.family}  [${pf.weights.join(", ")}]${pf.italic_supported ? " italic" : ""}`,
    );
    lines.push(`    source: ${pf.source}`);
    if (pf.files && pf.files.length > 0) {
      lines.push(`    files: ${pf.files.slice(0, 3).join(", ")}${pf.files.length > 3 ? " …" : ""}`);
    }
  }
  if (result.secondary_font) {
    const sf = result.secondary_font;
    lines.push(`  secondary: ${sf.family}  [${sf.weights.join(", ")}]`);
  }
  if (result.stack_css) lines.push(`  stack: ${result.stack_css}`);
  if (result.headings_stack_css) lines.push(`  headings: ${result.headings_stack_css}`);
  if (result.body_stack_css) lines.push(`  body: ${result.body_stack_css}`);
  if (result.found_at.length > 0) {
    lines.push(`  found in ${result.found_at.length} stylesheet(s)`);
  }
  return lines.join("\n");
}
