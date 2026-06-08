// files domain — workbook bundle / unbundle / spec bridge (Phase B).
//
// Thin reactive wrapper over the native Rust `workbook_bundle`,
// `workbook_unbundle`, and `workbook_spec_read` Tauri commands. All
// native/offline — no runtime/control-plane calls. Owns:
//   * an in-flight set so the UI can disable the menu item while
//     a bundle is running
//   * the path-derivation rules:
//       bundle:    <dir>           → <dir>.html  (sibling of dir)
//       unbundle:  <name>.html     → <name>-unbundled/
//
// Toast surfacing lives in the toast store (toasts.svelte.ts); this
// module pushes success / failure messages onto it.

import { invoke } from "@tauri-apps/api/core";
import { toasts } from "$lib/bridge/toasts.svelte";

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
      const result = await invoke<BundleResult>("workbook_bundle", {
        dir,
        output,
      });
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
      const result = await invoke<UnbundleResult>("workbook_unbundle", {
        htmlPath,
        outputDir,
      });
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
