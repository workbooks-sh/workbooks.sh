// `brandnana creative analyze` — vision analysis of ad creatives.
//
// SERVER-MANAGED BY DEFAULT (the agent path):
//   brandnana creative analyze --url <img> --kind image
//   brandnana creative analyze --url <vid> --kind video --poster <thumb>
//
//   The CLI POSTs to https://api.brandnana.net/v1/creative/analyze with the
//   brandnana API-key bearer (same getApiKey() as `book publish`). The WORKER
//   holds the OpenRouter key and runs the vision call, then returns the
//   structured `analysis`. The agent needs NO OpenRouter key — which matters
//   because the Workbooks engine SCRUBS every "*_API_KEY" env var from the
//   agent's bash (runtime/engine/.../tool_registry.ex @secret_substrings), so a
//   direct-from-bash OpenRouter call could never see a key.
//
//   THIS IS THE GENERAL PATTERN: any provider-keyed capability the agent needs
//   must be a CLI→server verb (mirrors `book publish` / `book render-slides`).
//   The CLI carries only the forwarded brandnana bearer; the server holds the
//   provider key in a binding and makes the upstream call.
//
// BATCH (`--file <path>` / stdin, a JSON array of creatives):
//   printf '%s' '[{"url":"<U1>","kind":"image"},{"url":"<U2>","kind":"image"}]' \
//     > /tmp/ads.json && brandnana creative analyze --file /tmp/ads.json
//   ALSO SERVER-MANAGED BY DEFAULT — it fans the same CLI→server analyze path
//   across every item with a bounded pool (--concurrency, default 8), carrying
//   only the brandnana bearer. So an agent can vision N ads in ONE call from the
//   scrubbed bash, no OpenRouter key, no per-URL orchestration. Emits
//   `{count, concurrency, analyses}`.
//
// LOCAL / OPERATOR ESCAPE HATCH (`--local`):
//   brandnana creative analyze --url <img> --kind image --local
//   brandnana creative analyze --file ads.json --local
//   Calls OpenRouter DIRECTLY from this process using OPENROUTER_API_KEY from
//   the environment. Only works where that key is present (a human's shell, a
//   CI box) — NOT in the scrubbed agent bash. Use it only when you deliberately
//   want the direct-OpenRouter path (e.g. a CI box validating the vision routing
//   without the worker in the loop); the server path above is the default for
//   both single AND batch.

import { readFileSync } from "node:fs";
import type { Command } from "commander";
import { getApiKey } from "../keychain.js";
import { emit, progress, runAction } from "../output.js";
import {
  type Creative,
  type CreativeAnalysis,
  analyzeCreative,
  pool,
} from "./creative-vision.js";

const ANALYZE_API_URL = "https://api.brandnana.net/v1/creative/analyze";

interface AnalyzeOptions {
  url?: string;
  kind?: "image" | "video";
  poster?: string;
  context?: string;
  file?: string;
  concurrency: string;
  local?: boolean;
}

function keysFromEnv(): { openrouter: string; gemini?: string } {
  const openrouter = process.env.OPENROUTER_API_KEY;
  if (!openrouter)
    throw new Error(
      "OPENROUTER_API_KEY is required for --local creative analysis. " +
        "Omit --local to use the server-managed path (no provider key needed).",
    );
  const gemini = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY;
  return gemini ? { openrouter, gemini } : { openrouter };
}

// Legacy grouped batch item: an ad carrying one OR many image slides (a
// carousel) as `urls:[...]`, kept for back-compat. The obvious per-creative
// shape `{url, kind, poster?, context?}` (matching the single --url form) is
// normalized to one Creative each; a grouped item with N>1 urls expands to N
// Creatives so the server path (one URL per call) handles every slide.
interface GroupedBatchItem {
  kind?: "image" | "video";
  urls?: string[];
  poster_url?: string | null;
  poster?: string | null;
  context?: string;
}

// Read the batch JSON (from --file or stdin) and normalize to Creative[].
// Accepts BOTH the obvious per-creative shape the agent naturally writes —
//   [{ url, kind, poster?, context? }, ...]
// and the legacy grouped shape —
//   [{ kind, urls:[...], poster_url?, context? }, ...]
// (or an object wrapper { creatives: [...] }). Mixed arrays are fine.
function readBatchCreatives(file?: string): Creative[] {
  const raw = file ? readFileSync(file, "utf8") : readFileSync(0, "utf8");
  const data = JSON.parse(raw) as unknown;
  const arr = Array.isArray(data) ? data : (data as { creatives?: unknown[] }).creatives;
  if (!Array.isArray(arr))
    throw new Error("expected a JSON array of creatives (or { creatives: [...] })");

  const out: Creative[] = [];
  for (const raw of arr) {
    const item = (raw ?? {}) as GroupedBatchItem & { url?: string };
    const kind: "image" | "video" = item.kind === "video" ? "video" : "image";
    const poster = item.poster ?? item.poster_url ?? undefined;
    if (typeof item.url === "string" && item.url) {
      // Obvious per-creative shape.
      out.push({ kind, url: item.url, poster_url: poster, context: item.context });
    } else if (Array.isArray(item.urls)) {
      // Legacy grouped shape — expand each slide URL to its own Creative so the
      // server path (one URL per call) covers every slide.
      for (const u of item.urls) {
        if (typeof u === "string" && u)
          out.push({ kind, url: u, poster_url: poster, context: item.context });
      }
    } else {
      throw new Error(
        'each batch item needs a "url" (e.g. {"url":"…","kind":"image"}) or a "urls" array',
      );
    }
  }
  if (out.length === 0) throw new Error("batch contained no creatives with a usable url");
  return out;
}

// ── Server-managed single-creative analysis (default) ────────────────────────
//
// POSTs to the worker, which holds the OpenRouter key. Returns the same
// CreativeAnalysis shape the local path produces, so the printed output (and the
// ad-vision skill that captures `analysis.summary`) is identical either way.
async function analyzeViaServer(c: Creative): Promise<CreativeAnalysis> {
  const apiKey = process.env.BRANDNANA_API_KEY ?? (await getApiKey());
  if (!apiKey) {
    throw new Error(
      "No API key found. Run `brandnana login` to sign in, or set BRANDNANA_API_KEY.",
    );
  }

  progress(`[brandnana] analyzing ${c.kind} via server…`);

  // One vision call per creative; with NO client deadline before, a hung
  // analysis blocked the agent's bash until the engine timeout cut it, then the
  // agent re-ran (the catalog-spin class). Own budget so a hang fails loud+fast.
  const analyzeTimeoutMs =
    Number.parseInt(process.env.WB_ANALYZE_TIMEOUT_MS ?? "", 10) || 120_000;
  let res: Response;
  try {
    res = await fetch(ANALYZE_API_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        url: c.url,
        kind: c.kind,
        ...(c.poster_url ? { poster: c.poster_url } : {}),
        ...(c.context ? { context: c.context } : {}),
      }),
      signal: AbortSignal.timeout(analyzeTimeoutMs),
    });
  } catch (e) {
    if (e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError")) {
      throw new Error(`creative analyze timed out after ${analyzeTimeoutMs}ms (${c.kind} ${c.url})`);
    }
    throw e;
  }

  if (!res.ok) {
    const text = await res.text().catch(() => "(no body)");
    throw new Error(`API error ${res.status}: ${text}`);
  }

  const body = (await res.json()) as { ok: boolean; analysis: CreativeAnalysis };
  return body.analysis;
}

export function registerCreative(program: Command): void {
  const creative = program.command("creative").description("Vision analysis of ad creatives");

  creative
    .command("analyze")
    .description(
      "Analyze ad creatives via the server (worker holds the OpenRouter key) — " +
        "one with --url/--kind, or a pooled batch with --file/stdin (a JSON array). " +
        "Both are server-managed by default; no provider key needed.",
    )
    .option("--url <url>", "Single creative URL (image or video)")
    .option("--kind <kind>", "image | video (for --url)")
    .option("--poster <url>", "Video poster/thumbnail URL (video fallback frame)")
    .option("--context <text>", "Ad copy/CTA text to give the model as context")
    .option(
      "--file <path>",
      "Read a JSON array of creatives from a file instead of stdin " +
        '(e.g. [{"url":"…","kind":"image"}, …]). Server-managed + pooled by default.',
    )
    .option("--concurrency <n>", "Max parallel analyses for a batch", "8")
    .option(
      "--local",
      "Call OpenRouter DIRECTLY using OPENROUTER_API_KEY from the env (operator/CI only; " +
        "does NOT work in the scrubbed agent bash). Use only to force the direct-OpenRouter " +
        "path; both single and batch are server-managed without it.",
      false,
    )
    .action((opts: AnalyzeOptions) =>
      runAction(async () => {
        const local = !!opts.local;
        const concurrency = Math.max(1, Number.parseInt(opts.concurrency, 10) || 8);

        // Single creative.
        if (opts.url) {
          const kind = opts.kind === "video" ? "video" : "image";
          const c: Creative = {
            kind,
            url: opts.url,
            poster_url: opts.poster,
            context: opts.context,
          };
          const analysis = local
            ? await analyzeCreative(c, keysFromEnv())
            : await analyzeViaServer(c);
          emit({ analyses: [analysis] }, analysis.summary || analysis.via);
          return;
        }

        // Batch (stdin/--file, a JSON array). SERVER-MANAGED BY DEFAULT: fan the
        // single server path across every creative with a bounded pool, carrying
        // only the brandnana bearer — so this works in the scrubbed agent bash
        // with NO OpenRouter key and N ads in ONE call. --local is the escape
        // hatch that runs the direct-OpenRouter path instead (operator/CI).
        const items = readBatchCreatives(opts.file);
        const analyses = local
          ? await (async () => {
              const keys = keysFromEnv(); // compute ONCE, not per-item
              return pool(items, concurrency, (c) => analyzeCreative(c, keys));
            })()
          : await pool(items, concurrency, (c) => analyzeViaServer(c));
        emit(
          { count: analyses.length, concurrency, analyses },
          `${analyses.length} creatives analyzed (concurrency ${concurrency})`,
        );
      }),
    );
}
