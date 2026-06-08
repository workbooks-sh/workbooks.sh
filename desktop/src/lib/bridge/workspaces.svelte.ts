/**
 * Top-level Workspaces bridge — mirrors Rust `workspaces.rs`.
 *
 * Per docs/canonical-model.md:
 *   User install → Workspace → Package
 *
 * This store owns the top-level Workspace layer. Packages (currently the
 * Rust `workspace_*` commands, soon to be renamed `package_*`) live in
 * `workspace.svelte.ts`.
 */

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { ws } from "./ws.svelte";

export interface SubtreeConfig {
  /** Remote git URL — `git@github.com:org/repo.git` or `https://…`. */
  remote_url: string;
  /** Branch on the remote (defaults to `main` when set via the UI). */
  branch: string;
}

export interface Workspace {
  id: string;
  name: string;
  /** Emoji or single-char icon. Empty = render initials. */
  icon: string;
  package_names: string[];
  created_at: number;
  /** Optional git-subtree config. When set, this workspace's directory
   *  inside the user-install monorepo is treated as a subtree against
   *  `remote_url`/`branch`. Unset = lives in the monorepo directly. */
  subtree?: SubtreeConfig | null;
}

class WorkspacesStore {
  workspaces = $state<Workspace[]>([]);
  active = $state<Workspace | null>(null);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;
  #liveUnsub: (() => void) | null = null;
  #fsUnsub: UnlistenFn | null = null;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
    // Live: refresh on any change to workspaces.org. The router routes
    // the firehose; no per-path channel join needed.
    this.#liveUnsub = ws.onMonorepoChange("workspaces.org", () => {
      void this.refresh();
    });
    // Also re-refresh on raw FS changes under monorepo/workspaces —
    // workspaces_list now merges in disk-discovered package folders,
    // so a new mkdir under <workspace>/ needs to trigger refresh.
    this.#fsUnsub = await listen<{ root: string }>(
      "fs-tree-changed",
      (e) => {
        const root = e.payload?.root ?? "";
        if (root.includes("/monorepo/workspaces")) {
          void this.refresh();
        }
      },
    );
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      this.workspaces = await invoke<Workspace[]>("workspaces_list");
      this.active = await invoke<Workspace | null>("workspaces_get_active");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  dispose() {
    this.#liveUnsub?.();
    this.#liveUnsub = null;
    this.#fsUnsub?.();
    this.#fsUnsub = null;
  }

  async create(name: string, icon: string = ""): Promise<Workspace> {
    const w = await invoke<Workspace>("workspaces_create", {
      req: { name, icon },
    });
    await this.refresh();
    return w;
  }

  async setActive(id: string | null): Promise<void> {
    await invoke("workspaces_set_active", { id });
    await this.refresh();
  }

  async rename(id: string, name: string): Promise<void> {
    await invoke("workspaces_rename", { req: { id, name } });
    await this.refresh();
  }

  async setIcon(id: string, icon: string): Promise<void> {
    await invoke("workspaces_set_icon", { req: { id, icon } });
    await this.refresh();
  }

  async delete(id: string): Promise<void> {
    await invoke("workspaces_delete", { id });
    await this.refresh();
  }

  async addPackage(workspace_id: string, package_name: string): Promise<void> {
    await invoke("workspaces_add_package", {
      req: { workspace_id, package_name },
    });
    await this.refresh();
  }

  async removePackage(
    workspace_id: string,
    package_name: string,
  ): Promise<void> {
    await invoke("workspaces_remove_package", {
      req: { workspace_id, package_name },
    });
    await this.refresh();
  }

  /** Set or clear the workspace's git-subtree config. Pass null to clear. */
  async setSubtree(
    id: string,
    subtree: SubtreeConfig | null,
  ): Promise<void> {
    await invoke("workspaces_set_subtree", { req: { id, subtree } });
    await this.refresh();
  }
}

export const workspaces = new WorkspacesStore();
