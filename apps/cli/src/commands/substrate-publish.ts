// `brandnana substrate publish [workdir]` — the DETERMINISTIC DURABLE-PUSH half
// of the gather → render → check → push pipeline.
//
// PROBLEM this fixes: the last step of a harvest must push the rendered substrate
// to durable, S3-backed gitwork storage so it survives a machine cycle
// (`WB_DATA_ROOT` is ephemeral `/tmp/wb` with no volume; only R2 media survives on
// its own). Relying on the LLM scout to hand-run `tar | base64 | curl POST
// /api/gitwork/push` failed: it emitted DONE without pushing, silently losing the
// substrate. This command makes the push a DETERMINISTIC, non-skippable step the
// agent runs as a single command.
//
// Behaviour: this verb FIRST re-runs the fidelity validator (validateSubstrate)
// and REFUSES to push a failing substrate — never publish synthesis. On a pass it
// archives the brand workdir, base64-encodes it, and POSTs it to the engine's
// gitwork push surface per the contract in checkpoint-substrate.org /
// gitwork_controller.ex:
//
//   POST {engineUrl}/api/gitwork/push
//   Authorization: Bearer $WB_ENGINE_BEARER (engine-injected per-session
//                  TenantToken) || $WB_PUBLIC_BEARER (single-mode/desktop)
//   body: { ref: "brand-<slug>/substrate", content: "<base64 tar.gz>", backend: "r2" }
//
// SECURITY (TENANCY-SECURITY.md §3.5): the tenant is carried inside the
// engine-injected TenantToken, so we send NO X-Tenant-Id header (a
// client-asserted tenant is spoofable and is rejected/ignored by the engine),
// and we push to the tenant-keyed durable `r2` backend rather than the unsafe
// shared `local` dir.
//
// Re-pushing the same ref overwrites (latest wins).
//
// Invocation:
//   brandnana substrate publish [workdir] [--ref <ref>] [--engine-url <url>]
//                                         [--db <path>] [--product-cap <n>]
//                                         [--run-window-start <iso>] [--run-window-end <iso>]

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Command } from "commander";
import { emit, runAction } from "../output.js";
import { resolveEngineBearer } from "../engine-auth.js";
import { formatReport, validateSubstrate } from "./substrate-check.js";

const DEFAULT_ENGINE_URL = "http://127.0.0.1:4000";

/** Strip a leading `brand-` so the slug is the bare brand name (tecovas). */
function slugFromWorkdir(workdir: string): string {
  return basename(workdir).replace(/^brand-/, "");
}

interface PublishOpts {
  ref?: string;
  engineUrl?: string;
  db?: string;
  productCap?: string;
  runWindowStart?: string;
  runWindowEnd?: string;
}

/**
 * Attach the `publish` verb to a parent `substrate` command. It runs the
 * fidelity check, then (only on pass) pushes the archived workdir to durable
 * gitwork storage. Mirrors attachSubstrateCheck so `build` / `check` / `publish`
 * live under one group.
 */
export function attachSubstratePublish(substrate: Command): void {
  substrate
    .command("publish [workdir]")
    .description(
      "Check then durably push the rendered substrate to gitwork S3-backed storage (refuses to push a failing substrate)",
    )
    .option("--ref <ref>", "gitwork ref to push to (default brand-<slug>/substrate)")
    .option(
      "--engine-url <url>",
      `engine base URL (default $WB_ENGINE_URL || ${DEFAULT_ENGINE_URL})`,
    )
    .option("--db <path>", "SQLite path (default <workdir>/.brandnana/brandnana.sqlite)")
    .option("--product-cap <n>", "Documented crawl cap; org count may equal min(dbCount, cap)")
    .option("--run-window-start <iso>", "Reject org timestamps before this ISO-8601 instant")
    .option("--run-window-end <iso>", "Reject org timestamps after this ISO-8601 instant")
    .action((workdirArg: string | undefined, opts: PublishOpts) =>
      runAction(async () => {
        const workdir = resolve(process.cwd(), workdirArg ?? ".");

        // (a) Validate FIRST — never push a failing substrate.
        const report = validateSubstrate(workdirArg ?? ".", {
          db: opts.db,
          runWindowStart: opts.runWindowStart,
          runWindowEnd: opts.runWindowEnd,
          productCap: opts.productCap != null ? Number.parseInt(opts.productCap, 10) : undefined,
        });
        if (!report.ok) {
          // Print the full report to stderr so the operator/agent sees what failed,
          // then fail loud — a failing substrate is NEVER published.
          process.stderr.write(`${formatReport(report)}\n`);
          throw new Error(
            `substrate check FAILED (${report.failed}/${report.checks.length} checks) — refusing to publish; fix the gather and re-run`,
          );
        }

        // (b) Archive the workdir to a tar.gz, then base64-encode it.
        const slug = slugFromWorkdir(workdir);
        const tgz = join(tmpdir(), `${slug}-substrate.tgz`);
        execFileSync("tar", ["-czf", tgz, "-C", dirname(workdir), basename(workdir)]);
        const archive = readFileSync(tgz);
        const content = archive.toString("base64");
        const bytes = archive.byteLength;

        // (c) POST to the engine's gitwork push surface.
        const engineUrl = (
          opts.engineUrl ??
          process.env.WB_ENGINE_URL ??
          DEFAULT_ENGINE_URL
        ).replace(/\/+$/, "");
        const ref = opts.ref ?? `brand-${slug}/substrate`;

        // Prefer the engine-injected per-session TenantToken (WB_ENGINE_BEARER):
        // it binds the tenant in a forgery-proof HMAC token. Fall back to the
        // static WB_PUBLIC_BEARER only for single-mode / desktop, where the
        // engine pins every request to default_tenant. No X-Tenant-Id header —
        // the tenant travels inside the token (TENANCY-SECURITY.md §3.5).
        const bearer = resolveEngineBearer();

        const headers: Record<string, string> = {
          "Content-Type": "application/json",
          Authorization: `Bearer ${bearer.token}`,
        };

        // Large base64 tar to the engine; with no client deadline a slow push
        // blocked the agent's bash until the engine cut it, then a re-run
        // re-pushed the whole tar (the catalog-spin class). Own budget.
        const pushTimeoutMs =
          Number.parseInt(process.env.WB_PUBLISH_TIMEOUT_MS ?? "", 10) || 180_000;
        let res: Response;
        try {
          res = await fetch(`${engineUrl}/api/gitwork/push`, {
            method: "POST",
            headers,
            body: JSON.stringify({ ref, content, backend: "r2" }),
            signal: AbortSignal.timeout(pushTimeoutMs),
          });
        } catch (e) {
          if (e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError")) {
            throw new Error(`gitwork push timed out after ${pushTimeoutMs}ms — the engine may still be writing`);
          }
          throw e;
        }

        const text = await res.text();
        if (!res.ok) {
          throw new Error(
            `gitwork push failed: ${res.status} ${res.statusText} — ${text.slice(0, 400)}`,
          );
        }

        let response: unknown = text;
        try {
          response = JSON.parse(text);
        } catch {
          // Non-JSON 2xx body — keep the raw text.
        }

        const kb = (bytes / 1024).toFixed(1);
        emit({ ok: true, ref, bytes, response }, `published ${ref} (${kb} KB)`);
      }),
    );
}

/**
 * Standalone registration: `brandnana substrate publish ...`. Reuses an existing
 * `substrate` group when the builder's registerSubstrate / registerSubstrateCheck
 * ran first, otherwise creates it — so `build` + `check` + `publish` share one
 * group regardless of registration order.
 */
export function registerSubstratePublish(program: Command): void {
  const existing = program.commands.find((c) => c.name() === "substrate");
  const substrate =
    existing ?? program.command("substrate").description("Deterministic substrate render & validation");
  attachSubstratePublish(substrate);
}
