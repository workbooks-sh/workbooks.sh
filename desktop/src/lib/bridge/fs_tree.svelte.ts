// wb-i38o.7 — file-tree bridge.
//
// Reactive front-end for the Tauri `tree_walk`, `tab_open`, and
// `open_in_os` commands plus the `fs-tree-changed` watcher event.
//
// Responsibilities:
//   * one walk per active-workspace folder, keyed by absolute path
//   * automatic re-walk on workspace switch (via workspace store
//     subscription, which fires on the underlying Rust event)
//   * debounced re-walk on `fs-tree-changed` so a burst of file
//     events (npm install, git checkout) coalesces into one walk

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface FsEntry {
  path: string;
  rel: string;
  name: string;
  is_dir: boolean;
  depth: number;
}

export interface TreeWalkResult {
  root: string;
  entries: FsEntry[];
  truncated: boolean;
}

interface FsTreeChangedPayload {
  root: string;
}

// Per-root walk timer; lets a noisy folder debounce independently.
const REFRESH_DEBOUNCE_MS = 250;

class FileTreeStore {
  /** root path → walk result. Absent entry = not walked yet. */
  trees = $state<Record<string, TreeWalkResult>>({});
  /** root path → "loading" | "ok" | "error" */
  status = $state<Record<string, "loading" | "ok" | "error">>({});
  /** root path → error string when status === 'error' */
  errors = $state<Record<string, string>>({});

  #unlisten: UnlistenFn | null = null;
  #initStarted = false;
  #debounceTimers = new Map<string, ReturnType<typeof setTimeout>>();

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;

    this.#unlisten = await listen<FsTreeChangedPayload>(
      "fs-tree-changed",
      (e) => {
        this.scheduleRefresh(e.payload.root);
      },
    );
  }

  /** Idempotent — drop trees for roots no longer in scope and walk
   *  newly-added roots. Called from the FileTreePanel component on
   *  every change to `workspace.active?.folders` (which the component
   *  already tracks reactively via $effect). Keeping the diff logic
   *  out of the store keeps the store free of $effect runes, which
   *  can only run inside a component effect root. */
  syncRoots(folders: string[]): void {
    const nextSet = new Set(folders);
    for (const gone of Object.keys(this.trees).filter((r) => !nextSet.has(r))) {
      delete this.trees[gone];
      delete this.status[gone];
      delete this.errors[gone];
    }
    for (const fresh of folders) {
      if (this.status[fresh] === undefined) {
        void this.walk(fresh);
      }
    }
  }

  destroy() {
    this.#unlisten?.();
    this.#unlisten = null;
    this.#initStarted = false;
    for (const t of this.#debounceTimers.values()) clearTimeout(t);
    this.#debounceTimers.clear();
  }

  async walk(root: string): Promise<void> {
    this.status[root] = "loading";
    try {
      const result = await invoke<TreeWalkResult>("tree_walk", { root });
      this.trees[root] = result;
      this.status[root] = "ok";
      delete this.errors[root];
    } catch (e) {
      this.status[root] = "error";
      this.errors[root] = e instanceof Error ? e.message : String(e);
    }
  }

  scheduleRefresh(root: string) {
    const existing = this.#debounceTimers.get(root);
    if (existing) clearTimeout(existing);
    this.#debounceTimers.set(
      root,
      setTimeout(() => {
        this.#debounceTimers.delete(root);
        void this.walk(root);
      }, REFRESH_DEBOUNCE_MS),
    );
  }

  async open(path: string): Promise<void> {
    // Calls into the D8 (tabbed viewer) tab_open if it has landed; else
    // this module's stub records the path for a later listener.
    await invoke("tab_open", { path });
  }

  async openInOs(path: string): Promise<void> {
    await invoke("open_in_os", { path });
  }
}

export const fileTree = new FileTreeStore();
