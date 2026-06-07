// Workers-compatible workbook bundler.
//
// The workbook-cli (Node, at cli/wb/forge/packages/workbook-cli/) cannot
// run inside a Cloudflare Worker. This module ports the minimum bundling logic
// needed to produce a valid .html:
//
//   1. Compose a source manifest JSON: { version, createdAt, rootName, files[] }
//   2. Gzip it with CompressionStream
//   3. Base64-encode the gzip bytes
//   4. Inject into the workbook shell HTML as a <script id="wb-source-bundle">
//   5. Inject the workbook-spec JSON as <script id="workbook-spec">
//
// Two shell modes:
//   - Brand-book mode (caller passes `bookData`): full self-contained Presentation
//     deck rendered by ./presentation-shell.ts — opens in any browser as a 10-slide
//     brand book.
//   - Placeholder mode (no bookData): minimal "install workbook CLI" stub.
//     Still a valid Workbooks workbook via the spec/source-bundle markers.
//
// Workbook HTML format — MUST match the forge unbundle contract exactly
// (cli/wb/forge/packages/workbook-cli/src/bundle/embedSource.mjs:34-53 +
//  commands/unbundle.mjs:38-43). `wb unbundle` HARD-REJECTS any bundle whose
// script tag is missing data-version="1":
//   <script id="workbook-spec" type="application/json">{ spec }</script>
//   <script id="wb-source-bundle" type="application/x-workbook-source"
//           data-format="json+gzip+base64" data-version="1"
//           data-file-count="N" data-bundle-size="B">{ base64 }</script>
//
// The OLD pipeline emitted the tag WITHOUT data-version, so every book failed
// `wb unbundle` (audit finding). All three render paths (this placeholder,
// presentation-shell.ts, document-shell.ts) now route through
// `renderSourceBundleScript()` below so the contract can never drift again.

import type { BookData } from "./presentation-shell.js";
import { renderPresentation } from "./presentation-shell.js";

// ── Source-bundle script tag (the forge unbundle contract) ─────────────────────

/**
 * Render the canonical `<script id="wb-source-bundle">` tag that `wb unbundle`
 * accepts. This is the SINGLE place the tag is emitted; all shells call it.
 *
 * Required by embedSource.mjs/unbundle.mjs:
 *   - id="wb-source-bundle"                    (block locator)
 *   - type="application/x-workbook-source"     (browser ignores it; zero runtime cost)
 *   - data-format="json+gzip+base64"           (unbundle.mjs:44 gate)
 *   - data-version="1"                         (unbundle.mjs:38 gate — was MISSING)
 *
 * Optional human-inspectable attrs we also stamp: data-file-count, data-bundle-size.
 *
 * Returns "" when `base64` is empty so preview/no-bundle callers (e.g. the
 * Stage-2 executor) emit no tag rather than an empty, unparseable one.
 */
export function renderSourceBundleScript(base64: string, fileCount?: number): string {
  if (!base64) return "";
  const attrs = [
    'id="wb-source-bundle"',
    'type="application/x-workbook-source"',
    'data-format="json+gzip+base64"',
    'data-version="1"',
  ];
  if (typeof fileCount === "number" && Number.isFinite(fileCount)) {
    attrs.push(`data-file-count="${fileCount}"`);
  }
  attrs.push(`data-bundle-size="${base64.length}"`);
  return `<script ${attrs.join(" ")}>${base64}</script>`;
}

// ── Workbook shell HTML ───────────────────────────────────────────────────────

// Minimal v1 shell. No WASM runtime is embedded here — that requires bundling
// oql-wasm (~2 MB) which is out of scope for the Worker. The workbook-spec
// marker is present so the file is identifiable as a workbook by any reader.
// The wb-0wst.6 epic will replace this with the full Theater UI.
const WORKBOOK_SHELL_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{title}}</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 640px; margin: 4rem auto; padding: 1rem; color: #111; }
  h1 { font-size: 1.5rem; font-weight: 700; margin-bottom: 0.5rem; }
  p { color: #444; line-height: 1.6; }
  code { background: #f4f4f4; padding: 0.2em 0.4em; border-radius: 3px; font-size: 0.9em; }
  .note { background: #fffbea; border: 1px solid #f0d060; padding: 1rem; border-radius: 6px; margin: 1.5rem 0; }
</style>
</head>
<body>
<h1>{{title}}</h1>
<p>This is a brandnana brand book packaged as a <strong>Workbooks workbook</strong>.</p>
<div class="note">
  <p>To view the full experience, install the Workbooks desktop app and open this file,
  or run: <code>wb unbundle {{slug}}.html</code></p>
</div>
<p>The brand data is embedded below as a gzip-compressed .org source bundle.</p>
<script id="workbook-spec" type="application/json">{{spec}}</script>
{{source_bundle_script}}
</body>
</html>`;

// ── Types ─────────────────────────────────────────────────────────────────────

export interface WorkbookFile {
  /** Relative path inside the workbook, e.g. "brand.org" */
  path: string;
  /** UTF-8 file content */
  content: string;
  /** Unix mode, e.g. 0o644. Stored as decimal. */
  mode?: number;
}

export interface WorkbookSpec {
  /** URL-safe identifier, e.g. "nike" */
  slug: string;
  /** Display title, e.g. "Nike brand book" */
  title: string;
  /** ISO-8601 generation timestamp */
  createdAt: string;
  /** brandnana version tag */
  generator?: string;
  /** Optional description */
  description?: string;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Encode Uint8Array to standard base64. Workers-compatible. */
function uint8ToBase64(bytes: Uint8Array): string {
  // btoa works on binary strings; convert via charCodeAt dance
  let binary = "";
  const len = bytes.length;
  for (let i = 0; i < len; i++) {
    binary += String.fromCharCode(bytes[i] ?? 0);
  }
  return btoa(binary);
}

/**
 * Compose the source-bundle JSON, gzip it, and return a base64 string.
 *
 * Manifest shape:
 *   { version: 1, createdAt: iso, rootName: slug, files: [{path, content, mode}] }
 */
async function buildSourceBundle(spec: WorkbookSpec, files: WorkbookFile[]): Promise<string> {
  const manifest = {
    version: 1,
    createdAt: spec.createdAt,
    rootName: spec.slug,
    files: files.map((f) => ({
      path: f.path,
      // content is stored as base64-encoded bytes inside the manifest
      content: btoa(unescape(encodeURIComponent(f.content))),
      mode: f.mode ?? 0o644,
    })),
  };
  const json = JSON.stringify(manifest);

  // Gzip via CompressionStream (Workers-native)
  const stream = new Response(
    new Blob([json]).stream().pipeThrough(new CompressionStream("gzip")),
  );
  const gzipBytes = new Uint8Array(await stream.arrayBuffer());
  return uint8ToBase64(gzipBytes);
}

// ── Main export ───────────────────────────────────────────────────────────────

/**
 * Bundle .org files into a self-contained workbook .html.
 *
 * If `bookData` is provided, the result is a full Presentation deck (opens
 * in any browser). Otherwise it's the minimal install-CLI placeholder. In
 * BOTH cases the workbook-spec + source-bundle markers are present so the
 * file is a valid Workbooks workbook.
 */
export async function bundleWorkbook(
  spec: WorkbookSpec,
  files: WorkbookFile[],
  bookData?: BookData,
): Promise<string> {
  const sourceBundle = await buildSourceBundle(spec, files);

  const workbookSpec = {
    slug: spec.slug,
    title: spec.title,
    createdAt: spec.createdAt,
    generator: spec.generator ?? "brandnana",
    description: spec.description ?? "",
    fileCount: files.length,
  };

  if (bookData) {
    return renderPresentation({
      data: bookData,
      workbookSpec,
      sourceBundleBase64: sourceBundle,
      sourceFileCount: files.length,
    });
  }

  return WORKBOOK_SHELL_HTML.replace("{{title}}", escapeHtml(spec.title))
    .replace("{{slug}}", escapeHtml(spec.slug))
    .replace("{{spec}}", JSON.stringify(workbookSpec))
    .replace("{{source_bundle_script}}", renderSourceBundleScript(sourceBundle, files.length));
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
