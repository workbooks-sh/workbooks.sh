// CLI output helpers — respect --json and --quiet global flags.
//
// All commands should use these instead of console.log / process.stdout
// directly so that --json gives machine-readable output, --quiet
// suppresses everything except the final result, and errors are
// formatted consistently (and ride out to a non-zero exit).

import { BrandnanaError } from "@brandnana/sdk";
import type { Command } from "commander";

export type OutputMode = "human" | "json" | "quiet";

let cachedMode: OutputMode | null = null;
let cachedProgram: Command | null = null;

export function bindOutputProgram(program: Command): void {
  cachedProgram = program;
  cachedMode = null;
}

function mode(): OutputMode {
  if (cachedMode) return cachedMode;
  const opts = (cachedProgram?.opts() ?? {}) as { json?: boolean; quiet?: boolean };
  cachedMode = opts.json ? "json" : opts.quiet ? "quiet" : "human";
  return cachedMode;
}

/** Print a status line (progress, info). Suppressed in --json and --quiet. */
export function say(msg: string): void {
  if (mode() === "human") {
    process.stdout.write(`${msg}\n`);
  }
}

/** Print to stderr regardless of mode (for warnings the user should see). */
export function warn(msg: string): void {
  if (mode() !== "json") {
    process.stderr.write(`! ${msg}\n`);
  }
}

/** Emit the final command result. In human/quiet mode prints `summary`; in
 *  json mode prints `JSON.stringify(payload)`. */
export function emit(payload: unknown, summary: string): void {
  const m = mode();
  if (m === "json") {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
  } else if (m === "human") {
    process.stdout.write(`${summary}\n`);
  }
  // quiet: print nothing on success
}

/** Format and print an error, then exit non-zero. */
export function emitError(err: unknown): never {
  const m = mode();
  const e = err instanceof Error ? err : new Error(String(err));
  const code = e instanceof BrandnanaError ? e.status : 1;
  if (m === "json") {
    const payload = {
      error: true,
      name: e.name,
      message: e.message,
      status: e instanceof BrandnanaError ? e.status : undefined,
      body: e instanceof BrandnanaError ? e.body : undefined,
    };
    process.stderr.write(`${JSON.stringify(payload)}\n`);
  } else {
    process.stderr.write(`brandnana: ${e.message}\n`);
    if (e instanceof BrandnanaError && e.body) {
      process.stderr.write(`  body: ${JSON.stringify(e.body)}\n`);
    }
  }
  process.exit(typeof code === "number" && code > 0 ? 1 : 1);
}

/** Stream a progress-style update: stderr in human mode, otherwise nothing. */
export function progress(msg: string): void {
  if (mode() === "human") {
    process.stderr.write(`${msg}\n`);
  }
}

/** Run an action with uniform error handling. */
export function runAction<T>(fn: () => Promise<T>): Promise<void> {
  return fn()
    .then(() => undefined)
    .catch(emitError);
}
