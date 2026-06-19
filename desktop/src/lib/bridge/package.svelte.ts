// files domain — package store (Phase B). Native package_* commands
// (fully offline).
//
// Reactive front-end for the native Tauri package_* commands. Owns:
//
//   * `workspaces` — the list of all defined packages by name
//   * `active` — the active package (folder list + name) or null
//
// Mutations refresh directly; the native `fs-tree-changed` watcher re-scans for
// out-of-band local writes (agent `mkdir`, external tools).

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { active } from "./_active.svelte";

/** File-tree view filter (wb-i38o.14). Mirrors the Rust `ViewMode`
 *  enum; serialised as the lowercase string the JSON contract uses. */
export type ViewMode = "source" | "compiled";

/** Detail-panel layout (wb-i38o.38). Mirrors the Rust `Layout` enum;
 *  serialised as the lowercase string the JSON contract uses. */
export type Layout = "grid" | "tree";

/** A workbook surfaced by the grid view — one entry per file in the
 *  Package whose head bytes contain the `<script id="workbook-spec">`
 *  marker (wb-i38o.37). */
export interface WorkbookEntry {
  path: string;
  title: string;
}

/** Default Package icon when the back-end omits one (pre-wb-i38o.34
 *  Packages have no on-disk ICON key). Mirrors the Rust-side default. */
export const DEFAULT_PACKAGE_ICON = "📦";

export interface Package {
  name: string;
  /** A package is either an `app` (a workbook — rendered as a bare icon) or a
   *  `folder` (a container — rendered as a folder glyph). Optional in payloads
   *  from a pre-folder-model backend; treat undefined as `"folder"`. */
  kind?: "app" | "folder";
  folders: string[];
  /** Single emoji / glyph rendered on the rail avatar and switcher.
   *  Optional in payloads from a pre-wb-i38o.34 backend; treat undefined
   *  as `DEFAULT_PACKAGE_ICON` at the call site. */
  icon?: string;
  /** Optional in payloads from a pre-D14 backend; treat undefined as
   *  `"source"` at the call site. */
  view_mode?: ViewMode;
  /** Default detail-panel layout (wb-i38o.38). Optional in payloads
   *  from a pre-wb-i38o.38 backend; treat undefined as `"grid"`. */
  layout?: Layout;
  /** Optional git-subtree config (parallel to the field on the
   *  top-level Workspace). When set, this Package's folder inside the
   *  monorepo is treated as a subtree against `remote_url`/`branch`.
   *  See docs/canonical-model.md. */
  subtree?: { remote_url: string; branch: string } | null;
}

interface ScopeChangePayload {
  workspace: string | null;
  folders: string[];
}

class PackageStore {
  workspaces = $state<string[]>([]);
  /** Per-package metadata cache keyed by name. Populated on every
   *  `refresh()` (one `package_load` per name, fired in parallel)
   *  so the rail can render real icons, not just initials. */
  meta = $state<Record<string, Package>>({});
  active = $state<Package | null>(null);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #unlisten: UnlistenFn | null = null;
  #unsubFsTree: UnlistenFn | null = null;
  #initStarted = false;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;

    // Mirror our `active` Package's workdir into the cross-store
    // `active` shared state so peer modules (ws, etc.) can read it
    // without importing this store and creating a cycle. Set up once
    // at init; runs on every PackageStore.active change thereafter.
    $effect.root(() => {
      $effect(() => {
        active.workdir = this.active?.folders?.[0] ?? null;
      });
    });

    // React to Rust-side package mutations.
    this.#unlisten = await listen<ScopeChangePayload>(
      "workspace-scope-change",
      async (e) => {
        // Hydrate the active store from the event payload before
        // pushing — the event IS authoritative for "what the agent
        // should see right now".
        if (e.payload.workspace === null) {
          this.active = null;
        } else {
          this.active = {
            name: e.payload.workspace,
            folders: e.payload.folders,
          };
        }
        await this.refresh();
      },
    );

    // Live: any FS change under the workspaces dir means a new
    // package folder may have appeared (created directly by the voice
    // agent's `mkdir`, or by an external tool). Re-scan so the rail
    // reflects on-disk reality immediately. Debounced inside the fs
    // watcher already.
    this.#unsubFsTree = await listen<{ root: string }>(
      "fs-tree-changed",
      async (e) => {
        const root = e.payload?.root ?? "";
        // Only react when the change is under the monorepo. Skip
        // changes to engine state / cache dirs.
        if (root.includes("/monorepo/workspaces")) {
          await this.refresh();
        }
      },
    );

    await this.refresh();
  }

  destroy() {
    this.#unlisten?.();
    this.#unsubFsTree?.();
    this.#unlisten = null;
    this.#unsubFsTree = null;
    this.#initStarted = false;
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      const names = await invoke<string[]>("package_list");
      this.workspaces = names;
      this.active = await invoke<Package | null>("package_get_active");
      // Hydrate the per-package metadata cache in parallel so the
      // rail's avatars can render icons (wb-i38o.34) and not just
      // initials. Failures on individual loads don't kill the whole
      // refresh — we just drop them from the cache.
      const loaded = await Promise.all(
        names.map(async (name): Promise<[string, Package] | null> => {
          try {
            const ws = await invoke<Package>("package_load", { name });
            return [name, ws];
          } catch {
            return null;
          }
        }),
      );
      const next: Record<string, Package> = {};
      for (const entry of loaded) {
        if (entry) next[entry[0]] = entry[1];
      }
      this.meta = next;
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async create(name: string, icon?: string): Promise<Package> {
    const ws = await invoke<Package>("package_create", { name, icon });
    await this.refresh();
    return ws;
  }

  /** Import an external folder as a new Package (wb-i38o.35).
   *  Recursively copies `sourcePath` into the monorepo at
   *  `~/Workbooks/monorepo/workspaces/<workspaceName>/<packageName>/`
   *  and creates the Package metadata pointing at the copied tree.
   *  Sync across machines is the user's git workflow — we don't
   *  symlink or path-reference. */
  async importFolder(
    workspaceName: string,
    packageName: string,
    sourcePath: string,
    icon?: string,
  ): Promise<Package> {
    const ws = await invoke<Package>("package_import_folder", {
      workspaceName,
      packageName,
      sourcePath,
      icon,
    });
    await this.refresh();
    return ws;
  }

  /** Persist the Package's display icon. Optimistic — updates the
   *  in-memory `active` immediately for an instant toggle feel. */
  async setIcon(name: string, icon: string): Promise<void> {
    if (this.active?.name === name) {
      this.active = { ...this.active, icon };
    }
    await invoke<Package>("package_set_icon", { name, icon });
    await this.refresh();
  }

  async load(name: string): Promise<Package> {
    return await invoke<Package>("package_load", { name });
  }

  async delete(name: string): Promise<void> {
    await invoke("package_delete", { name });
    await this.refresh();
  }

  async addFolder(name: string, path: string): Promise<Package> {
    const w = await invoke<Package>("package_add_folder", { name, path });
    await this.refresh();
    return w;
  }

  async removeFolder(name: string, path: string): Promise<Package> {
    const w = await invoke<Package>("package_remove_folder", {
      name,
      path,
    });
    await this.refresh();
    return w;
  }

  async setActive(name: string | null): Promise<void> {
    await invoke("package_set_active", { name });
    await this.refresh();
  }

  /** Persist the Package's default detail-panel layout (wb-i38o.38).
   *  Optimistic — the rail panel switcher should feel instant. */
  async setLayout(name: string, layout: Layout): Promise<void> {
    if (this.active?.name === name) {
      this.active = { ...this.active, layout };
    }
    await invoke<Package>("package_set_layout", { name, layout });
  }

  /** List the workbooks (files passing the workbook-spec marker scan)
   *  reachable from the Package's `folders`. One Tauri round-trip per
   *  call — the back-end parallelises the per-file marker scans. */
  async workbooks(name: string): Promise<WorkbookEntry[]> {
    return await invoke<WorkbookEntry[]>("package_workbooks", { name });
  }

  /** Persist the file-tree view filter for a workspace (wb-i38o.14).
   *  Updates the in-memory `active` immediately for an instant toggle
   *  feel — the Tauri round-trip is fire-and-forget. */
  async setViewMode(name: string, mode: ViewMode): Promise<void> {
    if (this.active?.name === name) {
      this.active = { ...this.active, view_mode: mode };
    }
    await invoke<Package>("package_set_view_mode", {
      name,
      viewMode: mode,
    });
  }

  /** Set or clear the Package's git-subtree config. Pass null to clear. */
  async setSubtree(
    name: string,
    subtree: { remote_url: string; branch: string } | null,
  ): Promise<Package> {
    const w = await invoke<Package>("package_set_subtree", {
      name,
      subtree,
    });
    if (this.active?.name === name) {
      this.active = { ...this.active, subtree: w.subtree ?? null };
    }
    return w;
  }
}

export const packageStore = new PackageStore();
