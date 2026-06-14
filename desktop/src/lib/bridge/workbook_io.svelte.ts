// files domain — workbook bundle / unbundle / spec bridge.
//
// De-Tauri'd (WORKBOOK-BUNDLE.md "Native everywhere"): the bundler is NOT a
// desktop Rust command — it's `Workbooks.Bundle` on the engine, reached over
// `/rcp/bundle` + `/rcp/unbundle` (the same BYTES-over-RCP seam checkout/checkin
// use, because the engine runs in a container and can't see host paths). The
// desktop is a pure caller: it only does file IO (read the dir tree / write the
// result) via the `bundle_read_tree` / `bundle_write_tree` Rust commands, then
// the engine does ALL zip/embed/loader/sign work. No bespoke Rust bundler.
//
//   bundle:   read tree → POST /rcp/bundle  → write returned .html
//   unbundle: POST /rcp/unbundle(.html)     → write returned tree
//
// Owns:
//   * an in-flight set so the UI can disable the menu item while running
//   * the path-derivation rules:
//       bundle:    <dir>           → <dir>.html  (sibling of dir)
//       unbundle:  <name>.html     → <name>-unbundled/
//
// Toast surfacing lives in the toast store (toasts.svelte.ts); this
// module pushes success / failure messages onto it.

import { invoke } from "@tauri-apps/api/core";
import { toasts } from "$lib/bridge/toasts.svelte";
import { engineRequest } from "$lib/engine-api/gen";

/** base64 ↔ bytes for the HTML round-trip through the engine. The tree's parts
 *  are base64'd by the Rust IO commands; the .html itself is base64'd here so a
 *  binary-clean payload survives the JSON hop in both directions. */
function b64encode(s: string): string {
  return btoa(unescape(encodeURIComponent(s)));
}
function b64decode(b: string): string {
  return decodeURIComponent(escape(atob(b)));
}

export interface BundleResult {
  output: string;
  stdout: string;
  stderr: string;
}

export interface UnbundleResult {
  output_dir: string;
  files: string[];
}

/** Result of `workbook_spec_read` — the parsed `<script id="workbook-spec">`
 *  payload, or null when the HTML has no spec marker. */
export interface WorkbookSpecResult {
  spec: unknown | null;
}

/** Strip a trailing slash. The Rust side normalises but the derived
 *  output paths look uglier with one. */
function trimSep(p: string): string {
  return p.endsWith("/") ? p.slice(0, -1) : p;
}

/** Drop a `.html`/`.htm` extension to build the unbundled sibling. */
function withoutHtmlExt(p: string): string {
  const lower = p.toLowerCase();
  if (lower.endsWith(".html")) return p.slice(0, -5);
  if (lower.endsWith(".htm")) return p.slice(0, -4);
  return p;
}

class WorkbookIoStore {
  /** Set of paths currently mid-bundle (keyed by the source dir). */
  inFlight = $state<Set<string>>(new Set());

  bundleOutputFor(dir: string): string {
    return `${trimSep(dir)}.html`;
  }

  unbundleOutputFor(htmlPath: string): string {
    return `${withoutHtmlExt(htmlPath)}-unbundled`;
  }

  async bundle(dir: string): Promise<BundleResult | null> {
    const output = this.bundleOutputFor(dir);
    if (this.inFlight.has(dir)) return null;
    this.inFlight.add(dir);
    const toastId = toasts.push({
      kind: "progress",
      message: `Bundling ${dir} …`,
    });
    try {
      // 1. Desktop reads the dir tree (raw bytes, base64) — file IO only.
      const files = await invoke<Record<string, string>>("bundle_read_tree", {
        dir,
      });
      // 2. Engine does ALL the bundling (zip + embed + loader) — the one home.
      const resp = await engineRequest<{ html_b64: string; files: string[] }>(
        "/rcp/bundle",
        { method: "POST", body: { files } },
      );
      // 3. Desktop writes the engine's self-contained .html out.
      const html = b64decode(resp.html_b64);
      await invoke("fs_write_file", { path: output, content: html });
      const result: BundleResult = {
        output,
        stdout: `bundled ${resp.files.length} files → ${output}`,
        stderr: "",
      };
      toasts.update(toastId, {
        kind: "success",
        message: `Bundled to ${result.output}`,
      });
      return result;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      toasts.update(toastId, {
        kind: "error",
        message: `Bundle failed: ${msg}`,
        sticky: true,
      });
      throw e;
    } finally {
      this.inFlight.delete(dir);
    }
  }

  async unbundle(htmlPath: string): Promise<UnbundleResult | null> {
    const outputDir = this.unbundleOutputFor(htmlPath);
    if (this.inFlight.has(htmlPath)) return null;
    this.inFlight.add(htmlPath);
    const toastId = toasts.push({
      kind: "progress",
      message: `Unbundling ${htmlPath} …`,
    });
    try {
      // 1. Desktop reads the .html source.
      const html = await invoke<string>("fs_read_file", { path: htmlPath });
      // 2. Engine extracts + unpacks the embedded bundle — the one home.
      const resp = await engineRequest<{ files: Record<string, string> }>(
        "/rcp/unbundle",
        { method: "POST", body: { b64: b64encode(html) } },
      );
      // 3. Desktop writes the parts (raw bytes, base64) back to disk — file IO.
      await invoke<number>("bundle_write_tree", {
        files: resp.files,
        dir: outputDir,
      });
      const result: UnbundleResult = {
        output_dir: outputDir,
        files: Object.keys(resp.files),
      };
      toasts.update(toastId, {
        kind: "success",
        message: `Unbundled ${result.files.length} files to ${result.output_dir}`,
      });
      return result;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      toasts.update(toastId, {
        kind: "error",
        message: `Unbundle failed: ${msg}`,
        sticky: true,
      });
      throw e;
    } finally {
      this.inFlight.delete(htmlPath);
    }
  }

  /** Read the `<script id="workbook-spec">` payload from an HTML file.
   *  Native + offline; returns `{ spec: null }` when no marker present. */
  async readSpec(htmlPath: string): Promise<WorkbookSpecResult> {
    return await invoke<WorkbookSpecResult>("workbook_spec_read", { htmlPath });
  }
}

export const workbookIo = new WorkbookIoStore();
