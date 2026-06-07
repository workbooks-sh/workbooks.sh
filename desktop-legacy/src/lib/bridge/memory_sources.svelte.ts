// wb-i38o.12 — Memory-source bridge.
//
// Manages the set of workbooks loaded as memory tiers for the OQL
// agent. Two-phase flow:
//   1. Tauri command `workbook_load_as_memory` does the scope check
//      + canonicalises the .html path on the Rust side.
//   2. The Phoenix WS bridge's `memory:control` channel asks the
//      Elixir sidecar to actually extract the bundle and index the
//      embedded .org files into the semantic memory tier.
//
// Toast surfacing piggybacks on the existing toast store.

import { invoke } from "@tauri-apps/api/core";
import { toasts } from "$lib/bridge/toasts.svelte";
import {
  ws,
  type AddWorkbookResult,
  type ListWorkbooksResult,
  type RemoveWorkbookResult,
} from "$lib/bridge/ws.svelte";

interface LoadResolution {
  canonical_path: string;
}

class MemorySourcesStore {
  /** Workbook paths the agent currently has loaded as memory sources. */
  loaded = $state<string[]>([]);

  /** Path → in-flight (true while add/remove is round-tripping). */
  inFlight = $state<Record<string, boolean>>({});

  /** Last refresh error message, if any. */
  lastError = $state<string | null>(null);

  /** Initial fetch — call once on mount of any UI that displays the set. */
  async refresh(): Promise<void> {
    try {
      const result = await ws.memoryControl<ListWorkbooksResult>(
        "list_workbooks",
        {},
      );
      this.loaded = result.workbooks ?? [];
      this.lastError = null;
    } catch (e) {
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
      // Tauri command: scope check + canonicalise the path.
      const resolved = await invoke<LoadResolution>(
        "workbook_load_as_memory",
        { htmlPath },
      );

      // Then ask the Elixir side to index it.
      const result = await ws.memoryControl<AddWorkbookResult>(
        "add_workbook",
        { path: resolved.canonical_path },
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
      const result = await ws.memoryControl<RemoveWorkbookResult>(
        "remove_workbook",
        { path: htmlPath },
      );
      this.loaded = this.loaded.filter((p) => p !== htmlPath);
      toasts.update(toastId, {
        kind: "success",
        message: `Removed ${result.entry_count} entries (${result.file_count} files) for ${htmlPath}`,
      });
      return result;
    } catch (e) {
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
