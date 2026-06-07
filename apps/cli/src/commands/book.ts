// brandnana book — AUTHOR a design-system deck, then publish it.
//
// The CANONICAL (and only) path is: author the deck HTML yourself with the
// design-system component library (the CSS classes documented in compose-deck.org
// + publish-workbook.org), then `book publish <slug> <deck.html>` to serve it.
//
// Sub-commands:
//   book publish <slug> <file>    upload an AUTHORED deck .html (the canonical path)
//   book render-slides <slug|url> render a published deck to per-slide PNGs (visual gate)
//   book ls                       list installed brand books
//   book show <slug>              print SKILL.md + BookMetadata
//   book open <slug>              open workbook in default browser
//   book query <slug> '<oql>'     run OQL query against the workbook source bundle
//   book insight-slides <dir>     emit ordered slide JSON from analysis/*.org

import {
  existsSync,
  readdirSync,
  readFileSync,
} from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { Command } from "commander";
import { getApiKey } from "../keychain.js";
import { extractBookMetadata } from "../book/extract-metadata.js";
import { emit, progress, runAction, say, warn } from "../output.js";
import { runBookQuery } from "./book-query.js";
import { runAssemble } from "./book-assemble.js";
import { analysisFilesToSlides } from "@brandnana/schema/analysis-slides";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PUBLISH_API_URL = "https://api.brandnana.net/v1/book/publish";
const RENDER_SLIDES_API_URL = "https://api.brandnana.net/v1/book/render-slides";
const SKILLS_BASE = join(homedir(), ".claude", "skills", "brands");

// ---------------------------------------------------------------------------
// Install-path helpers
// ---------------------------------------------------------------------------

function installDir(slug: string): string {
  return join(SKILLS_BASE, slug);
}

function workbookPath(slug: string, dir?: string): string {
  return join(dir ?? installDir(slug), `${slug}.workbook.html`);
}

function skillMdPath(slug: string, dir?: string): string {
  return join(dir ?? installDir(slug), "SKILL.md");
}

// Recursively collect every .org file under a directory (analysis/*.org plus
// nested families like analysis/ad-vision/*.org). Returns absolute paths sorted
// for deterministic output. Tolerant of a missing dir (returns []).
export function collectOrgFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, ent.name);
    if (ent.isDirectory()) out.push(...collectOrgFiles(full));
    else if (ent.isFile() && ent.name.endsWith(".org")) out.push(full);
  }
  return out.sort();
}

// ---------------------------------------------------------------------------
// POST /v1/book/render-slides — VISUAL-REVIEW gate
//
// Renders a PUBLISHED deck to per-slide PNGs (mirrored to R2) so the strategist
// can SEE each slide and self-correct. Accepts either a bare slug or a full
// deck URL (https://api.brandnana.net/books/<slug>.html).
// ---------------------------------------------------------------------------

interface SlideDefect {
  type: string;
  detail: string;
}

interface RenderSlidesResponse {
  ok: boolean;
  slug: string;
  deck_url: string;
  total: number;
  truncated: boolean;
  count: number;
  /** Total deterministic defects across all slides (overflow/clip/empty/broken). */
  defect_count?: number;
  slides: Array<{ index: number; key: string; url: string; defects?: SlideDefect[] }>;
  warning?: string;
}

/** Build the render-slides request body from a slug-or-URL argument. */
function renderSlidesBody(target: string): { slug?: string; url?: string } {
  const t = target.trim();
  if (/^https?:\/\//i.test(t)) return { url: t };
  // Strip a trailing .html if a bare "<slug>.html" was passed.
  return { slug: t.replace(/\.html$/i, "") };
}

export async function fetchRenderSlides(
  target: string,
  opts: { maxSlides?: number } = {},
): Promise<RenderSlidesResponse> {
  const apiKey = process.env.BRANDNANA_API_KEY ?? (await getApiKey());
  if (!apiKey) {
    throw new Error(
      "No API key found. Run `brandnana login` to sign in, or set BRANDNANA_API_KEY.",
    );
  }

  const body = {
    ...renderSlidesBody(target),
    ...(opts.maxSlides ? { max_slides: opts.maxSlides } : {}),
  };

  progress(`[brandnana] rendering slides for ${target}…`);

  // The render is a slow headless-Chromium pass (up to 60 slides) with NO
  // client deadline before — so a hung render blocked the WHOLE deck-gate
  // DONE_CHECK (120s ceiling) and each cut counted as a structural fail toward
  // DONE_CHECK_MAX, failing a perfect deck out (wb-kmt4). Give it its OWN budget
  // BELOW the done-check ceiling so a transport hang fails loud + fast instead.
  const renderTimeoutMs =
    Number.parseInt(process.env.WB_RENDER_TIMEOUT_MS ?? "", 10) || 90_000;
  let res: Response;
  try {
    res = await fetch(RENDER_SLIDES_API_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(renderTimeoutMs),
    });
  } catch (e) {
    if (e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError")) {
      throw new Error(
        `render-slides timed out after ${renderTimeoutMs}ms (raise WB_RENDER_TIMEOUT_MS, or render fewer slides) — the server render may still be running`,
      );
    }
    throw e;
  }

  if (!res.ok) {
    const text = await res.text().catch(() => "(no body)");
    throw new Error(`API error ${res.status}: ${text}`);
  }

  return (await res.json()) as RenderSlidesResponse;
}

// ---------------------------------------------------------------------------
// POST /v1/book/publish — upload a PRE-COMPOSED deck .html
//
// Reads a locally-composed standalone .html and uploads it VERBATIM so it is
// served at https://api.brandnana.net/books/<slug>.html (the same R2 key the
// public serve route reads). This is the path the strategist uses after it
// bundles a deck locally so `book render-slides` (the visual gate) and the
// public URL both resolve.
// ---------------------------------------------------------------------------

interface PublishResponse {
  ok: boolean;
  slug: string;
  url: string;
  bytes: number;
}

async function publishBook(slug: string, htmlFile: string): Promise<PublishResponse> {
  const apiKey = process.env.BRANDNANA_API_KEY ?? (await getApiKey());
  if (!apiKey) {
    throw new Error(
      "No API key found. Run `brandnana login` to sign in, or set BRANDNANA_API_KEY.",
    );
  }

  const path = resolve(htmlFile);
  if (!existsSync(path)) {
    throw new Error(`HTML file not found: ${path}`);
  }
  const html = await readFile(path, "utf8");

  progress(`[brandnana] publishing ${slug} (${html.length} bytes)…`);

  const res = await fetch(PUBLISH_API_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ slug, html }),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "(no body)");
    throw new Error(`API error ${res.status}: ${text}`);
  }

  return (await res.json()) as PublishResponse;
}

// ---------------------------------------------------------------------------
// `book ls` — list installed books
// ---------------------------------------------------------------------------

interface InstalledBook {
  slug: string;
  brand_name: string;
  generated_at: string;
  dir: string;
}

function listInstalledBooks(): InstalledBook[] {
  if (!existsSync(SKILLS_BASE)) return [];
  const slugs = readdirSync(SKILLS_BASE, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);

  return slugs.map((slug) => {
    const mdPath = skillMdPath(slug);
    let brand_name = slug;
    let generated_at = "";
    if (existsSync(mdPath)) {
      const text = readFileSync(mdPath, "utf8");
      // name: <slug>-brand  →  brand_name from description line or heading.
      const nameMatch = text.match(/^# (.+)$/m);
      if (nameMatch?.[1]) {
        brand_name = nameMatch[1].replace(/ brand book$/, "").trim();
      }
      // Generated <date> via ...
      const dateMatch = text.match(/^Generated (.+?) via/m);
      if (dateMatch?.[1]) generated_at = dateMatch[1].trim();
    }
    return { slug, brand_name, generated_at, dir: installDir(slug) };
  });
}

// ---------------------------------------------------------------------------
// Command registration
// ---------------------------------------------------------------------------

export function registerBook(program: Command): void {
  const book = program
    .command("book")
    .description(
      "AUTHOR a design-system deck then `book publish` it. " +
        "See `book publish`, `book render-slides`, `book ls`, `book query`.",
    );

  // ── assemble ─────────────────────────────────────────────────────────────
  // Assemble a deck-v2 HTML from a JSON slide spec — the design-system CSS shell,
  // slide wrappers, and doc assembly live in book-assemble.ts, NOT in a per-run
  // python helper. The Designer composes only the spec {palette, slides}; the
  // content slides carry inner component HTML. Then `wb embed-source` + `book
  // publish`. wb-x7md.
  book
    .command("assemble <spec>")
    .description(
      "Assemble a deck-v2 HTML from a spec (no python; do NOT inspect the binary).\n" +
        "<spec> is EITHER one spec.json OR a DIRECTORY (recommended for big decks: write\n" +
        "deck.json {title,creditR?,palette} + one NN-key.json per slide, assembled in name\n" +
        "order — incremental small writes, never one giant spec).\n" +
        "spec = {title, creditR?, palette:{stageBg,fg,fgMuted,fgSubtle,primary,secondary,accent,bone,line,fontDisplay,fontBody}, slides:[…]}\n" +
        "each slide is ONE of:\n" +
        "  {\"type\":\"splash\", eyebrow, h1, sub, img}\n" +
        "  {\"type\":\"act-divider\", roman, num, title, sub?}\n" +
        "  {\"type\":\"end-card\", mark, h1, line, meta}\n" +
        "  {\"type\":\"content\", density?(light|dense|fill), html, label?, cls?}  — html uses the design-system component classes (cat publish-workbook.org)\n" +
        "Then `wb embed-source deck.html .` + `book publish`.",
    )
    .option("--out <file>", "output HTML path", "deck.html")
    .action((spec: string, opts: { out: string }) =>
      runAction(async () => {
        const r = runAssemble(spec, opts.out);
        say(`assembled ${r.slides} slides → ${opts.out} (${r.bytes} bytes)`);
      }),
    );

  // ── ls ───────────────────────────────────────────────────────────────────
  book
    .command("ls")
    .description("List installed brand books")
    .action(() =>
      runAction(async () => {
        const books = listInstalledBooks();
        if (books.length === 0) {
          say("No brand books installed. Author a deck, then: brandnana book publish <slug> <deck.html>");
          emit([], "No brand books installed.");
          return;
        }

        // Aligned table.
        const slugW = Math.max(4, ...books.map((b) => b.slug.length));
        const nameW = Math.max(10, ...books.map((b) => b.brand_name.length));
        const header = `${"SLUG".padEnd(slugW)}  ${"BRAND_NAME".padEnd(nameW)}  GENERATED`;
        const sep = `${"-".repeat(slugW)}  ${"-".repeat(nameW)}  ${"-".repeat(16)}`;
        const rows = books.map(
          (b) => `${b.slug.padEnd(slugW)}  ${b.brand_name.padEnd(nameW)}  ${b.generated_at || "(unknown)"}`,
        );

        say([header, sep, ...rows].join("\n"));
        emit(books, `${books.length} brand book${books.length === 1 ? "" : "s"} installed`);
      }),
    );

  // ── show ─────────────────────────────────────────────────────────────────
  book
    .command("show <slug>")
    .description("Print SKILL.md and BookMetadata for an installed brand book")
    .action((slug: string) =>
      runAction(async () => {
        const mdPath = skillMdPath(slug);
        if (!existsSync(mdPath)) {
          throw new Error(
            `No installed book for slug "${slug}". Author a deck, then: brandnana book publish ${slug} <deck.html>`,
          );
        }

        const skillMd = await readFile(mdPath, "utf8");
        say(skillMd);
        say("\n---\n");

        const wbPath = workbookPath(slug);
        if (existsSync(wbPath)) {
          try {
            const meta = await extractBookMetadata(wbPath);
            say("BookMetadata (extracted from workbook):");
            say(JSON.stringify(meta, null, 2));
            emit({ skill_md: skillMd, meta }, skillMd);
            return;
          } catch (err) {
            warn(`Could not extract BookMetadata: ${(err as Error).message}`);
          }
        } else {
          warn(`workbook.html not found at ${wbPath}`);
        }

        emit({ skill_md: skillMd, meta: null }, skillMd);
      }),
    );

  // ── open ─────────────────────────────────────────────────────────────────
  book
    .command("open <slug>")
    .description("Open the brand book workbook in the default browser")
    .action((slug: string) =>
      runAction(async () => {
        const wbPath = workbookPath(slug);
        if (!existsSync(wbPath)) {
          throw new Error(
            `No installed book for slug "${slug}". Author a deck, then: brandnana book publish ${slug} <deck.html>`,
          );
        }

        const { platform } = process;
        let openCmd: string;
        if (platform === "darwin") {
          openCmd = `open "${wbPath}"`;
        } else if (platform === "linux") {
          openCmd = `xdg-open "${wbPath}"`;
        } else {
          say(`Open this file in your browser: ${wbPath}`);
          emit({ path: wbPath }, `Open: ${wbPath}`);
          return;
        }

        const { execSync } = await import("node:child_process");
        execSync(openCmd);
        emit({ path: wbPath }, `Opened: ${wbPath}`);
      }),
    );

  // ── query ────────────────────────────────────────────────────────────────
  book
    .command("query <slug> <oql>")
    .description(
      "Query the OQL source bundle embedded in an installed brand book workbook.\n" +
      "Supports: (under \"path\"), (tagged tag), (has property :KEY:).\n" +
      "For richer queries, install the oql CLI: brew install workbooks-sh/tap/oql",
    )
    .action((slug: string, oql: string) =>
      runAction(async () => {
        await runBookQuery(workbookPath(slug), oql);
      }),
    );

  // ── insight-slides ─────────────────────────────────────────────────────────
  // Deterministic analysis/*.org → ordered slide outline (JSON). The strategist
  // calls this when authoring the deck-v2 HTML so slide structure/order/grounds
  // come from a stable mapper instead of being improvised each run (wb-zkp4).
  book
    .command("insight-slides <dir>")
    .description(
      "Emit ordered slide JSON from a brand workdir's analysis/*.org insights.\n" +
      "Reads <dir>/analysis (or <dir> itself) recursively. Author the deck FROM this.",
    )
    .action((dir: string) =>
      runAction(async () => {
        const root = existsSync(join(dir, "analysis")) ? join(dir, "analysis") : dir;
        const orgFiles = collectOrgFiles(root).map((p) => readFileSync(p, "utf8"));
        const slides = analysisFilesToSlides(orgFiles);
        emit(slides, JSON.stringify(slides, null, 2));
      }),
    );

  // ── publish ────────────────────────────────────────────────────────────────
  // Upload a locally-composed deck .html so it is served at
  // https://api.brandnana.net/books/<slug>.html (the key the public serve route
  // reads). Run this AFTER bundling the deck and BEFORE `book render-slides` so
  // the visual-review gate has something to screenshot.
  book
    .command("publish <slug> <html-file>")
    .description(
      "Upload a locally-composed deck .html so it is served at /books/<slug>.html\n" +
        "(then run `brandnana book render-slides <slug>` for the visual-review gate).",
    )
    .action((slug: string, htmlFile: string) =>
      runAction(async () => {
        const r = await publishBook(slug, htmlFile);
        emit(
          r,
          [
            `[brandnana] published deck: ${r.slug} (${r.bytes} bytes)`,
            `  served: ${r.url}`,
            `  next:   brandnana book render-slides ${r.slug}`,
          ].join("\n"),
        );
      }),
    );

  // ── render-slides ──────────────────────────────────────────────────────────
  // VISUAL-REVIEW gate: render a PUBLISHED deck to per-slide PNGs so the
  // strategist can SEE each slide (then run `creative analyze --kind image` on
  // each PNG and self-correct). Accepts a bare slug or a full deck URL.
  book
    .command("render-slides <deck-url-or-slug>")
    .description(
      "Render a published deck to per-slide PNG images (mirrored to R2) for visual review.\n" +
        "Pipe each slide URL through `brandnana creative analyze --url <png> --kind image`.",
    )
    .option("--max-slides <n>", "Cap on slides rendered (default 60)")
    .action((target: string, opts: { maxSlides?: string }) =>
      runAction(async () => {
        const maxSlides = opts.maxSlides ? Number.parseInt(opts.maxSlides, 10) : undefined;
        const r = await fetchRenderSlides(target, {
          maxSlides: maxSlides && Number.isFinite(maxSlides) ? maxSlides : undefined,
        });

        const defectTotal =
          r.defect_count ?? r.slides.reduce((n, s) => n + (s.defects?.length ?? 0), 0);
        const lines = [
          `[brandnana] rendered ${r.count}/${r.total} slide${r.total === 1 ? "" : "s"} for ${r.slug}` +
            (defectTotal > 0 ? ` — ${defectTotal} defect${defectTotal === 1 ? "" : "s"}` : " — 0 defects"),
          ...(r.truncated ? [`  (truncated — deck has ${r.total} slides)`] : []),
          ...r.slides.map((s) => {
            const d = s.defects ?? [];
            const tag = d.length ? `  ⚠ ${d.map((x) => x.type).join(",")}` : "";
            return `  ${String(s.index).padStart(2, "0")} ${s.key.padEnd(12)} ${s.url}${tag}`;
          }),
          ...(r.warning ? [`  warning: ${r.warning}`] : []),
        ];

        emit(r, lines.join("\n"));
      }),
    );
}
