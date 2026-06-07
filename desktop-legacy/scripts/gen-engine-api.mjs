// Generates the desktop's engine API client surface from the shared verb
// schema (runtime/engine/priv/api-verbs.json) — the same file the engine
// dispatch table and the wb CLI route constants are compiled from.
//
// Output: src/lib/engine-api/gen.ts (gitignored). Run via the dev/build/
// typecheck scripts in package.json; never hand-edit the output, and
// never hand-write an "/api/..." path in desktop code.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const schemaPath = join(here, "../../runtime/engine/priv/api-verbs.json");
const outPath = join(here, "../src/lib/engine-api/gen.ts");

const { verbs } = JSON.parse(readFileSync(schemaPath, "utf8"));

const ident = (verb) => verb.replace(/[.-]/g, "_");

const lines = [
  "// @generated from runtime/engine/priv/api-verbs.json by scripts/gen-engine-api.mjs — do not edit.",
  "",
  "/** The one engine API error. Every engine-facing module throws this",
  " *  shape; there are no per-domain error classes. */",
  "export class EngineApiError extends Error {",
  "  code: string;",
  "  status: number;",
  "  constructor(code: string, message: string, status: number) {",
  "    super(message);",
  '    this.name = "EngineApiError";',
  "    this.code = code;",
  "    this.status = status;",
  "  }",
  "}",
  "",
  "/** HTTP method per verb, straight from the schema. */",
  "export const engineMethod = {",
];

for (const v of verbs) {
  lines.push(`  ${ident(v.verb)}: ${JSON.stringify(v.method)},`);
}
lines.push("} as const;", "", "/** Path (or path builder, for verbs with captures) per verb. */", "export const enginePath = {");

for (const v of verbs) {
  const params = [...v.path.matchAll(/\{(\w+)\}/g)].map((m) => m[1]);
  if (params.length === 0) {
    lines.push(`  ${ident(v.verb)}: ${JSON.stringify(v.path)},`);
  } else {
    const args = params.map((p) => `${p}: string`).join(", ");
    const tpl = v.path.replace(/\{(\w+)\}/g, (_, p) => `\${encodeURIComponent(${p})}`);
    lines.push(`  ${ident(v.verb)}: (${args}) => \`${tpl}\`,`);
  }
}
lines.push("} as const;", "");

lines.push(
  "",
  'import { sidecar } from "$lib/bridge/sidecar.svelte";',
  "",
  "export interface EngineRequestOptions {",
  "  method?: string;",
  '  /** Pre-built query string, starting with "?". */',
  "  query?: string;",
  "  /** JSON-encoded request body. */",
  "  body?: unknown;",
  "  /** Raw request body (overrides `body`); pair with `contentType`. */",
  "  bodyText?: string;",
  "  contentType?: string;",
  "  timeoutMs?: number;",
  "}",
  "",
  "/** The one transport for engine calls: sidecar guard, optional timeout,",
  " *  JSON decode, and normalization of every failure to EngineApiError",
  " *  (code from the engine's { error, message } envelope when present). */",
  "export async function engineRequest<T = unknown>(",
  "  path: string,",
  "  opts: EngineRequestOptions = {},",
  "): Promise<T> {",
  "  const base = sidecar.status.url;",
  "  if (!base) {",
  '    throw new EngineApiError("sidecar_down", "Agent server isn\'t running.", 0);',
  "  }",
  "  const ctrl = opts.timeoutMs ? new AbortController() : null;",
  "  const timer = ctrl ? setTimeout(() => ctrl.abort(), opts.timeoutMs) : null;",
  "  try {",
  "    const hasBody = opts.bodyText !== undefined || opts.body !== undefined;",
  "    const res = await fetch(`${base}${path}${opts.query ?? \"\"}`, {",
  '      method: opts.method ?? (hasBody ? "POST" : "GET"),',
  "      headers: {",
  '        accept: "application/json",',
  "        ...(hasBody",
  '          ? { "content-type": opts.contentType ?? "application/json" }',
  "          : {}),",
  "      },",
  "      body: opts.bodyText ?? (opts.body !== undefined ? JSON.stringify(opts.body) : undefined),",
  "      signal: ctrl?.signal,",
  "    });",
  "    const data = (await res.json().catch(() => null)) as {",
  "      error?: unknown;",
  "      message?: unknown;",
  "    } | null;",
  "    if (!res.ok) {",
  "      throw new EngineApiError(",
  '        typeof data?.error === "string" ? data.error : `http_${res.status}`,',
  '        typeof data?.message === "string" ? data.message : `HTTP ${res.status}`,',
  "        res.status,",
  "      );",
  "    }",
  "    return data as T;",
  "  } finally {",
  "    if (timer) clearTimeout(timer);",
  "  }",
  "}",
  "",
);

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, lines.join("\n"));
console.log(`gen-engine-api: wrote ${outPath} (${verbs.length} verbs)`);
