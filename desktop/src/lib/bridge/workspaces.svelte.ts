/**
 * Workspaces bridge — flat workspace registry (Phase B canonical schema).
 *
 * Per docs/canonical-model.md:
 *   User install → Workspace → Package
 *
 * PLACEMENT: **local-store**. The workspace registry is offline-first client
 * state persisted via tauri-plugin-store as `workspaces.json` with shape
 * `{ workspaces: Workspace[], active_id: string | null }`. No Rust command and
 * no runtime round-trip is required for any CRUD cap — the app boots and edits
 * workspaces fully offline.
 *
 * RUNTIME (graceful-offline): the optional control-plane can push a monorepo
 * "firehose" that we reconcile into the local registry. That path is still
 * pending on the runtime side; we subscribe best-effort and swallow
 * `daemon_down` so an offline sidecar never throws to the UI.
 *
 * NATIVE (pending): a future fs watcher will emit `fs-tree-changed`; we listen
 * best-effort and re-refresh when the changed root is under the workspaces dir.
 *
 * The exported `workspaces` store and its member names are the UI contract and
 * are kept stable; only the bodies + the underlying persistence change.
 *
 * Distinct from runtime `workspace.ex` (workspace.org manifest, DID/PATH
 * members) — that's the future reconcile target, not this flat id/name/icon
 * registry.
 */

import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { LazyStore } from "@tauri-apps/plugin-store";
import { engineRequest, EngineApiError } from "$lib/engine-api/gen";

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
  /** Unix epoch milliseconds. */
  created_at: number;
  /** Optional git-subtree config. When set, this workspace's directory
   *  inside the user-install monorepo is treated as a subtree against
   *  `remote_url`/`branch`. Unset = lives in the monorepo directly. */
  subtree?: SubtreeConfig | null;
}

interface WorkspacesFile {
  workspaces: Workspace[];
  active_id: string | null;
}

const STORE_FILE = "workspaces.json";
const WORKSPACES_KEY = "workspaces";
const ACTIVE_KEY = "active_id";

/** Lazily-opened plugin-store. `autoSave` off — we persist explicitly after
 *  each mutation so a refresh always reads a settled file. */
const store = new LazyStore(STORE_FILE, { autoSave: false });

async function readFile(): Promise<WorkspacesFile> {
  const [list, activeId] = await Promise.all([
    store.get<Workspace[]>(WORKSPACES_KEY),
    store.get<string | null>(ACTIVE_KEY),
  ]);
  return {
    workspaces: Array.isArray(list) ? list : [],
    active_id: typeof activeId === "string" ? activeId : null,
  };
}

async function writeFile(file: WorkspacesFile): Promise<void> {
  await store.set(WORKSPACES_KEY, file.workspaces);
  await store.set(ACTIVE_KEY, file.active_id);
  await store.save();
}

function newId(): string {
  // crypto.randomUUID is available in the Tauri webview; fall back defensively.
  try {
    return crypto.randomUUID();
  } catch {
    return `ws_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
  }
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

    // RUNTIME (pending, graceful-offline): reconcile on the control-plane
    // monorepo firehose. Best-effort — never throws to the UI when the
    // sidecar is down.
    this.#liveUnsub = this.#subscribeMonorepo();

    // NATIVE (pending): re-refresh on raw FS changes under the workspaces dir.
    this.#fsUnsub = await listen<{ root: string }>("fs-tree-changed", (e) => {
      const root = e.payload?.root ?? "";
      if (root.includes("/monorepo/workspaces")) {
        void this.refresh();
      }
    });
  }

  /** Best-effort runtime sync. Returns an unsubscribe. Degrades to a no-op
   *  when the sidecar is offline (`daemon_down`). The runtime route is still
   *  pending; until it exists this is a guarded poll that simply re-reconciles
   *  the local registry and stays quiet when the daemon isn't up. */
  #subscribeMonorepo(): () => void {
    let cancelled = false;
    void (async () => {
      try {
        // Pending runtime endpoint; calling it today returns `daemon_down`
        // when offline (swallowed below) or a 404 we ignore.
        await engineRequest("/api/workspaces/sync");
        if (cancelled) return;
        await this.refresh();
      } catch (e) {
        if (e instanceof EngineApiError && e.code === "daemon_down") return;
        // Any other runtime failure (e.g. route not yet implemented) is
        // non-fatal for an offline-first registry — stay silent.
      }
    })();
    return () => {
      cancelled = true;
    };
  }

  dispose() {
    this.#liveUnsub?.();
    this.#liveUnsub = null;
    this.#fsUnsub?.();
    this.#fsUnsub = null;
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      const file = await readFile();
      this.workspaces = file.workspaces;
      this.active =
        file.workspaces.find((w) => w.id === file.active_id) ?? null;
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  /** Read-modify-write helper. Loads the file, applies `f`, persists, refreshes
   *  reactive state. Mirrors the Rust `mutate(app,id,f)` helper. */
  async #mutate(f: (file: WorkspacesFile) => void): Promise<void> {
    const file = await readFile();
    f(file);
    await writeFile(file);
    await this.refresh();
  }

  async create(name: string, icon: string = ""): Promise<Workspace> {
    const w: Workspace = {
      id: newId(),
      name,
      icon,
      package_names: [],
      created_at: Date.now(),
      subtree: null,
    };
    await this.#mutate((file) => {
      file.workspaces.push(w);
    });
    return w;
  }

  async setActive(id: string | null): Promise<void> {
    await this.#mutate((file) => {
      file.active_id =
        id !== null && file.workspaces.some((w) => w.id === id) ? id : null;
    });
  }

  async rename(id: string, name: string): Promise<void> {
    await this.#mutate((file) => {
      const w = file.workspaces.find((w) => w.id === id);
      if (w) w.name = name;
    });
  }

  async setIcon(id: string, icon: string): Promise<void> {
    await this.#mutate((file) => {
      const w = file.workspaces.find((w) => w.id === id);
      if (w) w.icon = icon;
    });
  }

  async delete(id: string): Promise<void> {
    await this.#mutate((file) => {
      file.workspaces = file.workspaces.filter((w) => w.id !== id);
      if (file.active_id === id) file.active_id = null;
    });
  }

  async addPackage(workspace_id: string, package_name: string): Promise<void> {
    await this.#mutate((file) => {
      const w = file.workspaces.find((w) => w.id === workspace_id);
      if (w && !w.package_names.includes(package_name)) {
        w.package_names.push(package_name);
      }
    });
  }

  async removePackage(
    workspace_id: string,
    package_name: string,
  ): Promise<void> {
    await this.#mutate((file) => {
      const w = file.workspaces.find((w) => w.id === workspace_id);
      if (w) {
        w.package_names = w.package_names.filter((n) => n !== package_name);
      }
    });
  }

  /** Reorder a workspace's packages (the rail order) and persist. Names not
   *  currently in the workspace are ignored; any omitted are appended. */
  async reorderPackages(
    workspace_id: string,
    orderedNames: string[],
  ): Promise<void> {
    await this.#mutate((file) => {
      const w = file.workspaces.find((w) => w.id === workspace_id);
      if (!w) return;
      const set = new Set(w.package_names);
      const next = orderedNames.filter((n) => set.has(n));
      for (const n of w.package_names) if (!next.includes(n)) next.push(n);
      w.package_names = next;
    });
  }

  /** Set or clear the workspace's git-subtree config. Pass null to clear. */
  async setSubtree(id: string, subtree: SubtreeConfig | null): Promise<void> {
    await this.#mutate((file) => {
      const w = file.workspaces.find((w) => w.id === id);
      if (w) w.subtree = subtree;
    });
  }
}

export const workspaces = new WorkspacesStore();
