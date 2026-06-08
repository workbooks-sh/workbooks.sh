// files domain — file-tree bridge (Phase B, fully native/offline).
//
// Reactive front-end for the native Rust fs_* commands plus the
// `fs-tree-changed` watcher event (emitted by the notify-backed watcher
// started via `fs_watch_start`).
//
// All capabilities here are NATIVE (Rust shell, local) so the tree, file
// ops, and watch work fully offline. No runtime/control-plane calls.
//
// Responsibilities:
//   * one walk per active-package folder, keyed by absolute path
//   * native watch lifecycle (fs_watch_start / fs_watch_stop) per root
//   * debounced re-walk on `fs-tree-changed` so a burst of file events
//     (npm install, git checkout) coalesces into one walk
//   * file mutation helpers (rename/move, delete, mkdir, create file,
//     read/write text) — thin typed wrappers over the native commands
//   * reveal-in-Finder

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

/** One-level directory listing entry (fs_dir_read). */
export interface DirEntry {
  name: string;
  path: string;
  is_dir: boolean;
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
  /** roots we've started a native watcher for (so syncRoots can stop them). */
  #watched = new Set<string>();

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

  /** Idempotent — drop trees + watchers for roots no longer in scope and
   *  walk + watch newly-added roots. Called from the FileTreePanel
   *  component on every change to `packageStore.active?.folders`. Keeping
   *  the diff logic out of the store keeps the store free of $effect
   *  runes, which can only run inside a component effect root. */
  syncRoots(folders: string[]): void {
    const nextSet = new Set(folders);
    for (const gone of Object.keys(this.trees).filter((r) => !nextSet.has(r))) {
      delete this.trees[gone];
      delete this.status[gone];
      delete this.errors[gone];
      void this.#stopWatch(gone);
    }
    for (const fresh of folders) {
      if (this.status[fresh] === undefined) {
        void this.walk(fresh);
        void this.#startWatch(fresh);
      }
    }
  }

  destroy() {
    this.#unlisten?.();
    this.#unlisten = null;
    this.#initStarted = false;
    for (const t of this.#debounceTimers.values()) clearTimeout(t);
    this.#debounceTimers.clear();
    for (const root of [...this.#watched]) void this.#stopWatch(root);
  }

  async #startWatch(root: string): Promise<void> {
    if (this.#watched.has(root)) return;
    this.#watched.add(root);
    try {
      await invoke("fs_watch_start", { root });
    } catch (e) {
      this.#watched.delete(root);
      console.warn("[fs] fs_watch_start failed", e);
    }
  }

  async #stopWatch(root: string): Promise<void> {
    if (!this.#watched.has(root)) return;
    this.#watched.delete(root);
    try {
      await invoke("fs_watch_stop", { root });
    } catch (e) {
      console.warn("[fs] fs_watch_stop failed", e);
    }
  }

  async walk(root: string): Promise<void> {
    this.status[root] = "loading";
    try {
      const result = await invoke<TreeWalkResult>("fs_tree_walk", { root });
      this.trees[root] = result;
      this.status[root] = "ok";
      delete this.errors[root];
    } catch (e) {
      this.status[root] = "error";
      this.errors[root] = e instanceof Error ? e.message : String(e);
    }
  }

  /** One-level directory listing (fs_dir_read). Used by lazy tree
   *  expanders that don't want the full recursive walk. */
  async dirRead(path: string): Promise<DirEntry[]> {
    return await invoke<DirEntry[]>("fs_dir_read", { path });
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
    await invoke("tab_open", { path });
  }

  async openInOs(path: string): Promise<void> {
    await invoke("fs_reveal", { path });
  }

  // ── file mutations (all native, all offline) ──────────────────────

  /** Rename / move `from` → `to`. */
  async rename(from: string, to: string): Promise<void> {
    await invoke("fs_rename", { from, to });
  }

  /** Recursive delete of a file or directory. */
  async remove(path: string): Promise<void> {
    await invoke("fs_delete", { path });
  }

  /** mkdir -p. */
  async mkdir(path: string): Promise<void> {
    await invoke("fs_mkdir", { path });
  }

  /** Create an empty file (parents created as needed by the host). */
  async createFile(path: string): Promise<void> {
    await invoke("fs_create_file", { path });
  }

  /** Read a text file. */
  async readFile(path: string): Promise<string> {
    return await invoke<string>("fs_read_file", { path });
  }

  /** Write a text file (host mkdir-p's the parent). */
  async writeFile(path: string, content: string): Promise<void> {
    await invoke("fs_write_file", { path, content });
  }
}

export const fileTree = new FileTreeStore();
