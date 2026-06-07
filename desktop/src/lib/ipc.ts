/**
 * ipc.ts — the single app-facing IPC surface.
 *
 * Two layers:
 *   1. `commands` — the tauri-specta-shaped command object (re-exported
 *      from bindings.ts). One typed async fn per Rust `#[command]`.
 *   2. `ws` + `events` — the streaming bridge: Phoenix-channel pushes
 *      and Tauri event listeners that the command layer can't model
 *      (they're push, not request/response).
 *
 * Everything here returns MOCK data / no-op subscriptions today so the
 * app builds as a plain Vite SPA. Each touchpoint carries a TODO marking
 * what it forwards to once the Tauri shell + sidecar land.
 */

import { commands } from "./bindings";
import { isTauri, listen } from "./tauri";

export { commands };
export type * from "./bindings";

/* ─────────────────── Streaming event names ─────────────────── */

/** Tauri `emit`/`listen` channels the frontend subscribes to. The real
 *  shell wires these via `@tauri-apps/api/event`'s `listen<T>()`. */
export type IpcEvent =
  | "tabs-state"
  | "sidecar-state"
  | "sidecar-log"
  | "terminal-output"
  | "terminal-exit"
  | "workspace-scope-change"
  | "fs-tree-changed";

type Unsubscribe = () => void;
type EventHandler<T> = (payload: T) => void;

/**
 * Subscribe to a streaming Tauri event. In the desktop shell this binds the real
 * `@tauri-apps/api/event` listener (e.g. `sidecar-state` from the daemon bridge);
 * in a plain SPA it's a no-op so callers' teardown stays safe.
 */
export function on<T = unknown>(name: IpcEvent, fn: EventHandler<T>): Unsubscribe {
  if (!isTauri()) return () => {};

  let off: (() => void) | null = null;
  let cancelled = false;
  listen<T>(name, fn).then((u) => (cancelled ? u() : (off = u)));
  return () => {
    cancelled = true;
    off?.();
  };
}

export const events = { on };

/* ──────────────────────── WS bridge ────────────────────────── */

export interface MonorepoChangePayload {
  path: string;
}

/**
 * `ws` — the Phoenix-channel bridge to the engine sidecar. Pushes
 * workspace scope, watches the on-disk monorepo for changes, and runs
 * memory/control RPCs. Mocked here; the real bridge connects over the
 * sidecar websocket.
 */
export const ws = {
  /** Push the active workspace + its folders to the engine so the
   *  sidecar scopes its file watcher + memory index.
   *  TODO(sidecar): push over the Phoenix channel. */
  async pushWorkspaceScope(_scope: {
    workspace: string;
    folders: string[];
  }): Promise<void> {
    return;
  },

  /** Subscribe to monorepo file changes matching `pattern`. Used by
   *  reactive stores (themes, fs tree) to re-read on disk edits.
   *  TODO(sidecar): bind to the `fs-tree-changed` channel + filter. */
  onMonorepoChange(_pattern: string, _fn: (p: MonorepoChangePayload) => void): Unsubscribe {
    return () => {};
  },

  /** Memory/control RPC over the bridge (load/query/forget).
   *  TODO(sidecar): forward to the engine memory channel. */
  async memoryControl<T = unknown>(_action: string, _payload?: unknown): Promise<T> {
    return undefined as T;
  },

  /** Coarse connection-state subscription for the bridge itself.
   *  TODO(sidecar): emit on channel join/leave/error. */
  subscribe(_fn: (connected: boolean) => void): Unsubscribe {
    return () => {};
  },
};

/* ─────────────────────── Auth helper ───────────────────────── */

/** WorkOS PKCE loopback sign-in — opens the system browser and exchanges
 *  the code for a session stored in the OS keychain.
 *  TODO(tauri-shell): drive the loopback flow + keychain via the shell;
 *  today this just calls the mocked command. */
export async function signIn(brokerUrl: string) {
  return commands.networkWorkosSignIn({ brokerUrl });
}
