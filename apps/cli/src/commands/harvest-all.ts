// `brandnana harvest-all <domain>` — DETERMINISTIC orchestration of the harvest
// verbs with an exit-code contract.
//
// This is the Phase-A keystone of wb-qy3g: the brand-scout agent no longer
// hand-orchestrates the happy-path sweep (resolve → identity → company →
// catalog → social → ads → creative → build → check → publish). That sequence
// is FIXED — every step, its flags, and the workspace paths are the same on
// every brand — so a script runs it. The agent becomes an exception-handler:
// it runs `harvest-all`, and only when the script ESCALATES (writes
// raw/escalate.json + exits non-zero) does the LLM step in to recover the one
// point that genuinely resisted.
//
// The canonical order + the deterministic workspace layout mirror the Worker's
// in-process harvester `harvestBrand` (apps/api/src/book/harvest.ts:721) and the
// brand-scout's hand-run playbook (profile/skills/harvest-sweep.org):
//
//   resolve → brand fetch --include all --mirror → logo --mirror →
//   design tokens → company (jq projection) → catalog crawl --mirror →
//   social fan-out (per discovered handle) → ads search --source all --mirror →
//   creative analyze (if creatives) → substrate build → substrate check →
//   substrate publish
//
// ── Verb-invocation approach: SUBPROCESS, not in-process. ──
// Each sibling verb (a) writes to the SQLite at `process.cwd()`, (b) mutates the
// module-level output.js `mode()` cache, (c) emits a `[brandnana-cost]` marker to
// stderr, and (d) some `process.exit(1)` on failure (e.g. `substrate check`).
// Calling the action functions in-process would tangle all of that shared state.
// We instead re-invoke THIS SAME CLI per stage (process.execPath + this bundle's
// entry, falling back to the `brandnana` on PATH) with `cwd: workdir` — so every
// stage gets a clean process, its own real exit code (the contract), and exactly
// reproduces the hand-run sweep. No stale-binary trap: harvest-all never shells a
// different `brandnana` than the one it is part of.

import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Command } from "commander";
import { emit, runAction, say, warn } from "../output.js";

// ── Stage + escalate types ───────────────────────────────────────────────────

/** A short, machine-readable reason for the FIRST failing stage. */
type EscalateReason =
  | "init-failed"
  | "resolve-null"
  | "brand-fetch-failed"
  | "logo-all-rejected"
  | "design-tokens-failed"
  | "company-projection-failed"
  | "catalog-cascade-exhausted"
  | "social-failed"
  | "ads-failed"
  | "creative-analyze-failed"
  | "substrate-build-failed"
  | "check-failed"
  | "publish-failed";

/** The escalation handoff to the agent — written to raw/escalate.json. */
interface Escalation {
  stage: string;
  reason: EscalateReason;
  exit_code: number;
  /** stderr tail / message — enough for the agent to act, not a full dump. */
  detail: string;
  /** Names of stages that completed cleanly before the failure. */
  completed_stages: string[];
  /** The harvest SQLite the recovery agent MUST target (NOT the default
   *  .brandnana/ path) — every brandnana verb needs `--db <db_path>` or its
   *  re-crawl lands in the wrong DB and the substrate stays broken. */
  db_path: string;
}

interface SpawnResult {
  code: number;
  stdout: string;
  stderr: string;
}

interface RunOptions {
  workdir: string;
}

// ── Subprocess plumbing ──────────────────────────────────────────────────────

/**
 * Re-invoke THIS CLI. process.argv[1] is the bundle entry (dist/index.js or
 * src/index.ts under bun); process.execPath is the node/bun that runs it. We
 * pass through --json / --quiet so the children honor the global output mode.
 */
function selfArgv(): { exe: string; prefix: string[] } {
  // A bun-compiled binary (prod): process.execPath IS the brandnana executable and
  // process.argv[1] is the internal "/$bunfs/…" path — NOT a runnable script, so
  // re-invoke the binary directly with no script arg. In dev (`bun run
  // src/index.ts`) argv[1] is the real entry and must be passed.
  const argv1 = process.argv[1] ?? "";
  const compiled = argv1 === "" || argv1.startsWith("/$bunfs/");
  return compiled ? { exe: process.execPath, prefix: [] } : { exe: process.execPath, prefix: [argv1] };
}

function globalOutputFlags(): string[] {
  const flags: string[] = [];
  if (process.argv.includes("--json")) flags.push("--json");
  if (process.argv.includes("--quiet")) flags.push("--quiet");
  return flags;
}

/** Last few non-empty lines of a stream, capped — the agent gets signal, not a dump. */
function tail(text: string, lines = 6, max = 1200): string {
  const kept = text
    .split("\n")
    .map((l) => l.trimEnd())
    .filter((l) => l.length > 0)
    .slice(-lines)
    .join("\n");
  return kept.length > max ? `…${kept.slice(-max)}` : kept;
}

/**
 * Run `brandnana <args>` in the workdir, capturing stdio. A verb that writes its
 * JSON to a file via `redirectTo` has stdout streamed there (so the workdir lane
 * is populated exactly as the scout's `> raw/x.json` would). The cost marker on
 * stderr is captured to `<costFile>` when given.
 */
function runVerb(
  workdir: string,
  args: string[],
  opts: { redirectTo?: string; costFile?: string } = {},
): Promise<SpawnResult> {
  const { exe, prefix } = selfArgv();
  return new Promise((resolveP) => {
    const child = execFile(
      exe,
      [...prefix, ...globalOutputFlags(), ...args],
      { cwd: workdir, maxBuffer: 64 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const code = err && typeof err.code === "number" ? err.code : err ? 1 : 0;
        if (opts.redirectTo) {
          try {
            writeFileSync(join(workdir, opts.redirectTo), stdout ?? "");
          } catch {
            /* best-effort: the verb's own exit code is the source of truth */
          }
        }
        if (opts.costFile) {
          const marker = (stderr ?? "")
            .split("\n")
            .find((l) => l.includes("[brandnana-cost]"));
          if (marker) {
            try {
              writeFileSync(join(workdir, opts.costFile), `${marker}\n`);
            } catch {
              /* cost capture is best-effort per harvest-sweep.org */
            }
          }
        }
        resolveP({ code, stdout: stdout ?? "", stderr: stderr ?? "" });
      },
    );
    // execFile's callback already covers spawn errors via `err`; nothing else to do.
    void child;
  });
}

// ── Tiny JSON readers (defensive — strict tsconfig, untrusted shapes) ─────────

function readJson(workdir: string, rel: string): Record<string, unknown> | null {
  const p = join(workdir, rel);
  if (!existsSync(p)) return null;
  try {
    const parsed: unknown = JSON.parse(readFileSync(p, "utf8"));
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function asObj(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

function asStr(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

/** Derive a bare social handle from a profile URL (harvest.ts:554-564). */
function handleFromUrl(url: string): string | null {
  try {
    const u = new URL(url.startsWith("http") ? url : `https://${url}`);
    const last = u.pathname.split("/").filter(Boolean).pop() ?? "";
    return last.replace(/^@/, "") || null;
  } catch {
    return null;
  }
}

function normDomain(raw: string): string {
  return raw.replace(/^https?:\/\//i, "").replace(/\/+$/, "").toLowerCase();
}

// ── Stage runners ─────────────────────────────────────────────────────────────
//
// Each returns either a string DETAIL on failure (caller escalates) or null on
// success. Stages append their name to `completed` as they pass.

const DB_REL = "catalog/.brandnana/brandnana.sqlite";

/**
 * STAGE 0 — deterministic workspace setup. mkdir the lanes every downstream verb
 * + the builder expect. Kills the agent's DB-path-discovery thrash: the SQLite
 * lives at catalog/.brandnana/brandnana.sqlite, and every verb is pointed there
 * with --db so they never each default to ./.brandnana/ in their own cwd.
 */
function setupWorkspace(workdir: string): void {
  mkdirSync(workdir, { recursive: true });
  for (const lane of ["raw", "social", join("catalog", ".brandnana")]) {
    mkdirSync(join(workdir, lane), { recursive: true });
  }
}

/**
 * STAGE 0b — init the SQLite schema (migrate). Every --db verb (brand fetch, catalog
 * crawl, ads) assumes its tables exist (sync_runs etc.); only `brandnana init` runs
 * the bundled migrations. Idempotent — safe even if a later verb also migrates.
 */
async function stageInit(workdir: string): Promise<string | null> {
  const r = await runVerb(workdir, ["init", "--db", DB_REL]);
  return r.code === 0 ? null : `init exited ${r.code}: ${tail(r.stderr || r.stdout)}`;
}

/** STAGE 1 — resolve. Given a domain, this is `as-given`; we still record it. */
async function stageResolve(workdir: string, input: string): Promise<{ domain: string } | string> {
  // The input is already a domain (the verb takes <domain>). We run resolve to
  // canonicalize a name-or-domain; on a clean domain it returns it as the top
  // candidate. A null/empty result is the resolve-null escalation.
  const r = await runVerb(workdir, ["resolve", input, "--json", "--limit", "5"], {
    redirectTo: "raw/resolve.json",
    costFile: "resolve_cost.txt",
  });
  if (r.code !== 0) {
    // resolve itself failing is rare; fall back to the literal input domain so
    // a transient resolver error doesn't sink an obvious domain.
    const literal = normDomain(input);
    if (literal.includes(".")) return { domain: literal };
    return `resolve exited ${r.code}: ${tail(r.stderr)}`;
  }
  const j = readJson(workdir, "raw/resolve.json");
  const candidates = Array.isArray(j?.candidates) ? (j?.candidates as unknown[]) : [];
  const recIdx = typeof j?.recommended === "number" ? (j?.recommended as number) : 0;
  const rec = asObj(candidates[recIdx] ?? candidates[0]);
  const domain = asStr(rec?.domain) ?? (normDomain(input).includes(".") ? normDomain(input) : null);
  if (!domain) return `resolve returned no usable domain for "${input}"`;
  return { domain };
}

/** STAGE 2 — identity: brand fetch (logo+palette+fonts+screenshot+styleguide). */
async function stageBrandFetch(workdir: string, domain: string): Promise<string | null> {
  const r = await runVerb(
    workdir,
    ["brand", "fetch", domain, "--include", "all", "--mirror", "--db", DB_REL, "--json"],
    { redirectTo: "raw/brand.json", costFile: "brand_fetch_cost.txt" },
  );
  return r.code === 0 ? null : `brand fetch exited ${r.code}: ${tail(r.stderr)}`;
}

/** STAGE 3 — logo cascade (--mirror). A rejected-all cascade is the escalation. */
async function stageLogo(workdir: string, domain: string): Promise<string | null> {
  const r = await runVerb(workdir, ["logo", domain, "--mirror", "--json"], {
    redirectTo: "raw/logo.json",
    costFile: "logo_cost.txt",
  });
  if (r.code !== 0) return `logo exited ${r.code}: ${tail(r.stderr)}`;
  const j = readJson(workdir, "raw/logo.json");
  const recommended = typeof j?.recommended === "number" ? (j?.recommended as number) : -1;
  const candidates = Array.isArray(j?.candidates) ? (j?.candidates as unknown[]) : [];
  // recommended === -1 (or no candidates) means the cascade rejected everything —
  // the honest logo-all-rejected escalation (never fall back to a favicon).
  if (recommended < 0 || candidates.length === 0) {
    return "logo cascade rejected every candidate (recommended=-1) — no mirrored wordmark";
  }
  return null;
}

/** STAGE 4 — design tokens (unioned palette ≥6). */
async function stageDesignTokens(workdir: string, domain: string): Promise<string | null> {
  const r = await runVerb(workdir, ["design", "tokens", domain, "--json"], {
    redirectTo: "raw/tokens.json",
    costFile: "design_tokens_cost.txt",
  });
  return r.code === 0 ? null : `design tokens exited ${r.code}: ${tail(r.stderr)}`;
}

/**
 * STAGE 5 — company projection. There is NO `brand company` verb; the builder
 * reads raw/company.json, so we project it out of raw/brand.json deterministically
 * (the jq recipe in harvest-sweep.org §3, done here in-process). Firmographics
 * pass through as the real nulls — never stubbed. Returns the socials handle set.
 */
function stageCompany(workdir: string): { socials: Record<string, string> } | string {
  const brand = readJson(workdir, "raw/brand.json");
  if (!brand) return "raw/brand.json missing — brand fetch did not land its JSON";

  // Unwrap descriptors_json (may be a stringified JSON blob) where industry +
  // socials + description live.
  let descriptors: Record<string, unknown> | null = null;
  const dRaw = brand.descriptors_json;
  if (typeof dRaw === "string") {
    try {
      descriptors = asObj(JSON.parse(dRaw));
    } catch {
      descriptors = null;
    }
  } else {
    descriptors = asObj(dRaw);
  }

  const socialsRaw =
    asObj(descriptors?.socials) ?? asObj(brand.socials) ?? {};
  const socials: Record<string, string> = {};
  for (const [k, v] of Object.entries(socialsRaw)) {
    const url = asStr(v);
    if (url) socials[k.toLowerCase()] = url;
  }

  const company = {
    name: asStr(brand.name) ?? asStr(brand.title) ?? null,
    description: asStr(descriptors?.description) ?? null,
    tagline: asStr(descriptors?.slogan) ?? null,
    industry: asStr(descriptors?.industry) ?? asStr(brand.industry) ?? null,
    socials,
    founded: null,
    city: null,
    country: null,
    employeeCount: null,
    revenue: null,
  };

  try {
    writeFileSync(join(workdir, "raw/company.json"), `${JSON.stringify(company, null, 2)}\n`);
  } catch (e) {
    return `failed to write raw/company.json: ${(e as Error).message}`;
  }
  return { socials };
}

/** STAGE 6 — catalog crawl (--strategy auto --mirror), streams into SQLite. */
async function stageCatalog(workdir: string, domain: string): Promise<string | null> {
  const r = await runVerb(
    workdir,
    ["catalog", "crawl", domain, "--strategy", "auto", "--mirror", "--db", DB_REL, "--json"],
    { redirectTo: "catalog/crawl.json", costFile: "catalog_crawl_cost.txt" },
  );
  // A 409 (crawl already ran) surfaces as a non-zero exit; the catalog verb's own
  // message tells the agent to re-run. We escalate so the agent decides — it has
  // the SQLite count to confirm the products already persisted.
  return r.code === 0 ? null : `catalog crawl exited ${r.code}: ${tail(r.stderr)}`;
}

/**
 * STAGE 7 — social fan-out. Per discovered handle (instagram/tiktok/youtube/
 * linkedin), profile + posts/videos → social/<platform>-*.json. Platforms with
 * no handle are true-negatives, skipped silently (not a failure). A verb that
 * errors on a discovered handle escalates.
 */
async function stageSocial(
  workdir: string,
  socials: Record<string, string>,
): Promise<string | null> {
  // platform → [profileVerb, postsVerb] (the exact CLI verb names per social.ts)
  const plan: Array<{ key: string; platform: string; profile: string; posts: string }> = [
    { key: "instagram", platform: "instagram", profile: "profile", posts: "posts" },
    { key: "tiktok", platform: "tiktok", profile: "profile", posts: "videos" },
    { key: "youtube", platform: "youtube", profile: "channel", posts: "videos" },
    { key: "linkedin", platform: "linkedin", profile: "company", posts: "posts" },
  ];

  for (const p of plan) {
    const url = socials[p.key];
    const handle = url ? handleFromUrl(url) : null;
    if (!handle) continue; // true-negative: no handle for this platform

    const prof = await runVerb(
      workdir,
      ["social", p.platform, p.profile, handle, "--json"],
      { redirectTo: `social/${p.platform}-${p.profile}.json` },
    );
    if (prof.code !== 0) {
      return `social ${p.platform} ${p.profile} ${handle} exited ${prof.code}: ${tail(prof.stderr)}`;
    }
    const posts = await runVerb(
      workdir,
      ["social", p.platform, p.posts, handle, "--json"],
      { redirectTo: `social/${p.platform}-${p.posts}.json` },
    );
    if (posts.code !== 0) {
      return `social ${p.platform} ${p.posts} ${handle} exited ${posts.code}: ${tail(posts.stderr)}`;
    }
  }
  return null;
}

/** STAGE 8 — ads search (--source all --mirror), scoped to the brand name. */
async function stageAds(workdir: string, query: string): Promise<string | null> {
  const r = await runVerb(
    workdir,
    ["ads", "search", query, "--source", "all", "--mirror", "--db", DB_REL, "--json"],
    { redirectTo: "raw/ads-all.json", costFile: "ads_search_cost.txt" },
  );
  return r.code === 0 ? null : `ads search exited ${r.code}: ${tail(r.stderr)}`;
}

/**
 * STAGE 9 — creative analyze, ONLY if ads returned creatives with images. Builds
 * the batch from raw/ads-all.json and feeds it via --file (server-managed, no
 * OpenRouter key needed in the scrubbed agent bash). No creatives → skip clean.
 */
async function stageCreative(workdir: string): Promise<string | null> {
  const j = readJson(workdir, "raw/ads-all.json");
  const results = Array.isArray(j?.results) ? (j?.results as unknown[]) : [];
  const creatives: Array<{ url: string; kind: string }> = [];
  for (const row of results) {
    const o = asObj(row);
    const url =
      asStr(o?.media_url) ?? asStr(o?.creative_url) ?? asStr(asObj(o?.media)?.url) ?? null;
    if (url) creatives.push({ url, kind: "image" });
  }
  if (creatives.length === 0) return null; // true-negative: nothing to analyze

  try {
    writeFileSync(join(workdir, "raw/ads-creatives.json"), JSON.stringify(creatives));
  } catch (e) {
    return `failed to stage creatives for analysis: ${(e as Error).message}`;
  }
  const r = await runVerb(
    workdir,
    ["creative", "analyze", "--file", "raw/ads-creatives.json", "--json"],
    { redirectTo: "raw/ads-vision.json", costFile: "creative_analyze_cost.txt" },
  );
  return r.code === 0 ? null : `creative analyze exited ${r.code}: ${tail(r.stderr)}`;
}

/** STAGE 10 — substrate build (deterministic render). */
async function stageBuild(workdir: string): Promise<string | null> {
  const r = await runVerb(workdir, ["substrate", "build", "--db", DB_REL]);
  return r.code === 0 ? null : `substrate build exited ${r.code}: ${tail(r.stderr || r.stdout)}`;
}

/** STAGE 11 — substrate check (the fidelity gate; process.exit(1) on fail). */
async function stageCheck(workdir: string): Promise<string | null> {
  const r = await runVerb(workdir, ["substrate", "check", "--db", DB_REL]);
  return r.code === 0 ? null : `substrate check FAILED (exit ${r.code}): ${tail(r.stdout || r.stderr)}`;
}

/** STAGE 12 — substrate publish (re-checks then durable gitwork push). */
async function stagePublish(workdir: string): Promise<string | null> {
  const r = await runVerb(workdir, ["substrate", "publish", "--db", DB_REL]);
  return r.code === 0 ? null : `substrate publish exited ${r.code}: ${tail(r.stderr || r.stdout)}`;
}

// ── Escalation handoff ────────────────────────────────────────────────────────

function escalate(
  workdir: string,
  stage: string,
  reason: EscalateReason,
  detail: string,
  completed: string[],
): never {
  const payload: Escalation = {
    stage,
    reason,
    exit_code: 1,
    detail: tail(detail),
    completed_stages: completed,
    db_path: DB_REL,
  };
  try {
    writeFileSync(join(workdir, "raw/escalate.json"), `${JSON.stringify(payload, null, 2)}\n`);
  } catch {
    /* even if we can't write the file, we still fail loud below */
  }
  warn(
    `harvest-all ESCALATE at stage "${stage}" (${reason}): ${payload.detail}\n` +
      `  → raw/escalate.json written; completed: ${completed.join(", ") || "(none)"}`,
  );
  process.exit(1);
}

// ── Command registration ──────────────────────────────────────────────────────

export function registerHarvestAll(program: Command): void {
  program
    .command("harvest-all <domain>")
    .description(
      "Deterministically run the full harvest sweep (resolve → identity → company → " +
        "catalog → social → ads → creative → substrate build/check/publish) with an " +
        "exit-code contract: on the FIRST failing stage, write raw/escalate.json and exit non-zero.",
    )
    .option("--workdir <dir>", "Workspace directory (default: cwd)", ".")
    .action((domain: string, opts: { workdir: string }) =>
      runAction(async () => {
        const run: RunOptions = { workdir: resolve(process.cwd(), opts.workdir) };
        const wd = run.workdir;
        const completed: string[] = [];

        // ── STAGE 0: workspace ──
        setupWorkspace(wd);
        say(`harvest-all ${domain} → ${wd}`);
        say("· stage 0: workspace lanes (raw/ social/ catalog/.brandnana/)");

        // ── STAGE 0b: init the SQLite schema (so every --db verb has its tables) ──
        say("· stage 0b: init SQLite schema");
        const inited = await stageInit(wd);
        if (inited) escalate(wd, "init", "init-failed", inited, completed);
        completed.push("init");

        // ── STAGE 1: resolve ──
        say("· stage 1: resolve");
        const resolved = await stageResolve(wd, domain);
        if (typeof resolved === "string") {
          escalate(wd, "resolve", "resolve-null", resolved, completed);
        }
        const canonical = resolved.domain;
        const brandQuery = canonical.replace(/^www\./, "").split(".")[0] ?? canonical;
        completed.push("resolve");
        say(`  → ${canonical}`);

        // ── STAGE 2: identity / brand fetch ──
        say("· stage 2: brand fetch --include all --mirror");
        const bf = await stageBrandFetch(wd, canonical);
        if (bf) escalate(wd, "brand-fetch", "brand-fetch-failed", bf, completed);
        completed.push("brand-fetch");

        // ── STAGE 3: logo --mirror ──
        say("· stage 3: logo --mirror");
        const logo = await stageLogo(wd, canonical);
        if (logo) escalate(wd, "logo", "logo-all-rejected", logo, completed);
        completed.push("logo");

        // ── STAGE 4: design tokens ──
        say("· stage 4: design tokens");
        const tokens = await stageDesignTokens(wd, canonical);
        if (tokens) escalate(wd, "design-tokens", "design-tokens-failed", tokens, completed);
        completed.push("design-tokens");

        // ── STAGE 5: company projection ──
        say("· stage 5: company (project raw/company.json)");
        const company = stageCompany(wd);
        if (typeof company === "string") {
          escalate(wd, "company", "company-projection-failed", company, completed);
        }
        completed.push("company");

        // ── STAGE 6: catalog crawl --mirror ──
        say("· stage 6: catalog crawl --strategy auto --mirror");
        const catalog = await stageCatalog(wd, canonical);
        if (catalog) escalate(wd, "catalog", "catalog-cascade-exhausted", catalog, completed);
        completed.push("catalog");

        // ── STAGE 7: social fan-out ──
        say("· stage 7: social fan-out");
        const social = await stageSocial(wd, company.socials);
        if (social) escalate(wd, "social", "social-failed", social, completed);
        completed.push("social");

        // ── STAGE 8: ads search --source all --mirror ──
        say("· stage 8: ads search --source all --mirror");
        const ads = await stageAds(wd, brandQuery);
        if (ads) escalate(wd, "ads", "ads-failed", ads, completed);
        completed.push("ads");

        // ── STAGE 9: creative analyze (if creatives) ──
        say("· stage 9: creative analyze (if creatives)");
        const creative = await stageCreative(wd);
        if (creative) escalate(wd, "creative", "creative-analyze-failed", creative, completed);
        completed.push("creative");

        // ── STAGE 10: substrate build ──
        say("· stage 10: substrate build");
        const built = await stageBuild(wd);
        if (built) escalate(wd, "substrate-build", "substrate-build-failed", built, completed);
        completed.push("substrate-build");

        // ── STAGE 11: substrate check ──
        say("· stage 11: substrate check");
        const checked = await stageCheck(wd);
        if (checked) escalate(wd, "substrate-check", "check-failed", checked, completed);
        completed.push("substrate-check");

        // ── STAGE 12: substrate publish ──
        say("· stage 12: substrate publish");
        const published = await stagePublish(wd);
        if (published) escalate(wd, "substrate-publish", "publish-failed", published, completed);
        completed.push("substrate-publish");

        // ── Done. ──
        const crawl = readJson(wd, "catalog/crawl.json");
        const productCount = Array.isArray(crawl?.products)
          ? (crawl?.products as unknown[]).length
          : null;
        const summary =
          `harvest-all ${canonical}: OK — all ${completed.length} stages passed` +
          (productCount != null ? ` (${productCount} products)` : "");
        emit(
          { ok: true, domain: canonical, completed_stages: completed, productCount },
          summary,
        );
      }),
    );
}
