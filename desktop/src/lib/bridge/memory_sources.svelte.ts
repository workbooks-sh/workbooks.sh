// Phase B — Memory-source bridge.
//
// Manages the set of workbooks loaded as memory tiers for the
// agent. Two-phase flow:
//   1. Native Tauri command `memory_source_resolve` does the scope check
//      + canonicalises the .html path on the Rust side (offline-safe).
//   2. The runtime control-plane REST surface (/api/memory/sources)
//      asks the Elixir daemon to extract the bundle and index the
//      embedded .org files into the semantic memory tier.
//
// The runtime tier is optional: when the daemon is offline, list/add/
// remove degrade gracefully (empty / no-op) instead of throwing to the
// UI. Toast surfacing piggybacks on the existing toast store.

import { invoke } from "@tauri-apps/api/core";
import { toasts } from "$lib/bridge/toasts.svelte";
import { engineRequest, EngineApiError } from "$lib/engine-api/gen";
import {
  type AddWorkbookResult,
  type RemoveWorkbookResult,
} from "$lib/bridge/ws.svelte";

interface LoadResolution {
  canonical_path: string;
}

/** Shape of GET /api/memory/sources. */
interface ListWorkbooksResult {
  workbooks: string[];
}

/** True when the failure is "the optional runtime tier isn't running".
 *  Tolerates both the new `daemon_down` code and the legacy `sidecar_down`
 *  the transport may still emit until gen.ts is renamed. */
function isDaemonDown(e: unknown): boolean {
  return (
    e instanceof EngineApiError &&
    (e.code === "daemon_down" || e.code === "sidecar_down")
  );
}

class MemorySourcesStore {
  /** Workbook paths the agent currently has loaded as memory sources. */
  loaded = $state<string[]>([]);

  /** Path → in-flight (true while add/remove is round-tripping). */
  inFlight = $state<Record<string, boolean>>({});

  /** Last refresh error message, if any. */
  lastError = $state<string | null>(null);

  /** Initial fetch — call once on mount of any UI that displays the set.
   *  Daemon offline ⇒ empty set, no error. */
  async refresh(): Promise<void> {
    try {
      const result = await engineRequest<ListWorkbooksResult>(
        "/api/memory/sources",
      );
      this.loaded = result.workbooks ?? [];
      this.lastError = null;
    } catch (e) {
      if (isDaemonDown(e)) {
        this.loaded = [];
        this.lastError = null;
        return;
      }
      this.lastError = e instanceof Error ? e.message : String(e);
    }
  }

  /** Load a `.html` workbook into the agent's semantic memory. */
  async add(htmlPath: string): Promise<AddWorkbookResult | null> {
    if (this.inFlight[htmlPath]) return null;
    this.inFlight = { ...this.inFlight, [htmlPath]: true };
    const toastId = toasts.push({
      kind: "progress",
      message: `Loading ${htmlPath} as memory source …`,
    });
    try {
      // Native: scope check + canonicalise the path (works offline).
      const resolved = await invoke<LoadResolution>("memory_source_resolve", {
        htmlPath,
      });

      // Then ask the runtime tier to index it.
      const result = await engineRequest<AddWorkbookResult>(
        "/api/memory/sources",
        { method: "POST", body: { path: resolved.canonical_path } },
      );

      // Reflect locally; refresh is overkill since we know the new path.
      if (!this.loaded.includes(result.workbook_path)) {
        this.loaded = [...this.loaded, result.workbook_path].sort();
      }

      toasts.update(toastId, {
        kind: "success",
        message: `Loaded ${result.indexed_count}/${result.file_count} files from ${result.workbook_path}`,
      });
      return result;
    } catch (e) {
      if (isDaemonDown(e)) {
        toasts.update(toastId, {
          kind: "error",
          message:
            "Memory load needs the agent server, which isn't running.",
          sticky: true,
        });
        return null;
      }
      const msg = e instanceof Error ? e.message : String(e);
      toasts.update(toastId, {
        kind: "error",
        message: `Memory load failed: ${msg}`,
        sticky: true,
      });
      throw e;
    } finally {
      this.inFlight = { ...this.inFlight, [htmlPath]: false };
    }
  }

  /** Remove the entries indexed from a previously-loaded workbook. */
  async remove(htmlPath: string): Promise<RemoveWorkbookResult | null> {
    if (this.inFlight[htmlPath]) return null;
    this.inFlight = { ...this.inFlight, [htmlPath]: true };
    const toastId = toasts.push({
      kind: "progress",
      message: `Removing memory source ${htmlPath} …`,
    });
    try {
      const result = await engineRequest<RemoveWorkbookResult>(
        "/api/memory/sources",
        { method: "DELETE", body: { path: htmlPath } },
      );
      this.loaded = this.loaded.filter((p) => p !== htmlPath);
      toasts.update(toastId, {
        kind: "success",
        message: `Removed ${result.entry_count} entries (${result.file_count} files) for ${htmlPath}`,
      });
      return result;
    } catch (e) {
      if (isDaemonDown(e)) {
        toasts.update(toastId, {
          kind: "error",
          message:
            "Memory remove needs the agent server, which isn't running.",
          sticky: true,
        });
        return null;
      }
      const msg = e instanceof Error ? e.message : String(e);
      toasts.update(toastId, {
        kind: "error",
        message: `Memory remove failed: ${msg}`,
        sticky: true,
      });
      throw e;
    } finally {
      this.inFlight = { ...this.inFlight, [htmlPath]: false };
    }
  }

  /** Helper for the file-tree dot indicator. */
  isLoaded(absPath: string): boolean {
    return this.loaded.includes(absPath);
  }
}

export const memorySources = new MemorySourcesStore();
