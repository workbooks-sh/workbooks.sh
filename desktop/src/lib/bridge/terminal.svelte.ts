// Terminal bridge — multi-session. ALL native (offline). Phase B.
//
// Three flavors of session live in the drawer:
//
//   1. `daemon`  — pinned, read-only "logs" view. Streams stdout/stderr
//      from the the runtime via the `daemon-log` Tauri event (emitted by
//      the long-lived daemon.rs capture). Not a pty; just lines piped
//      into xterm. Always present.
//   2. `shell`   — interactive shell (zsh/bash/cmd) backed by a real
//      pty (portable_pty) on the Rust side. Spawned via terminal_spawn.
//   3. `install` — one-shot child command (brew, npm, curl) spawned
//      via `terminalDrawer.runInstall(...)`. Same pty machinery as
//      shells; the drawer marks them as one-shots so the UI can tag
//      them differently and so they exit naturally.
//
// The drawer component (`TerminalDrawer.svelte`) owns the actual
// xterm.js instances; this bridge owns metadata + IPC to the Rust
// pty (terminal_*) + the daemon log subscription.
//
// Commands (snake_case, native): terminal_spawn / terminal_write /
// terminal_resize / terminal_kill.
// Events (native): terminal-output / terminal-exit / daemon-log.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

// "daemon" replaces the legacy "sidecar" kind. Exported type name kept
// stable for the UI.
export type SessionKind = "daemon" | "shell" | "install";

export interface SessionMeta {
  id: string;
  label: string;
  kind: SessionKind;
  /** "running" | "exited" | "failed". UI shows a status dot per session. */
  state: "running" | "exited" | "failed";
  /** Last exit code, if any. */
  exit_code: number | null;
  /** Whether the user can close this session — false for the pinned daemon log session. */
  closable: boolean;
}

export interface SpawnOptions {
  cols: number;
  rows: number;
  shell?: string;
  command?: string[];
  cwd?: string;
}

interface OutputEvent {
  session_id: string;
  data: string;
}

interface ExitEvent {
  session_id: string;
  exit_code: number | null;
}

interface DaemonLogEvent {
  stream: "stdout" | "stderr";
  line: string;
}

type OutputHandler = (bytes: Uint8Array) => void;
type ExitHandler = (code: number | null) => void;

function decodeB64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function encodeB64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

/** The canonical id for the pinned daemon logs session. Not a real
 *  Rust pty id — the drawer special-cases it. Export name kept stable
 *  for the UI; the underlying id value is now "daemon-logs". */
export const SIDECAR_SESSION_ID = "daemon-logs";

class TerminalBridge {
  #onOutput = new Map<string, OutputHandler>();
  #onExit = new Map<string, ExitHandler>();
  #onDaemonLog: ((e: DaemonLogEvent) => void) | null = null;
  #unlisteners: UnlistenFn[] = [];
  #started = false;

  async ensureStarted(): Promise<void> {
    if (this.#started) return;
    this.#started = true;

    this.#unlisteners.push(
      await listen<OutputEvent>("terminal-output", (e) => {
        const fn = this.#onOutput.get(e.payload.session_id);
        if (fn) fn(decodeB64(e.payload.data));
      }),
    );

    this.#unlisteners.push(
      await listen<ExitEvent>("terminal-exit", (e) => {
        const fn = this.#onExit.get(e.payload.session_id);
        if (fn) fn(e.payload.exit_code);
      }),
    );

    // daemon-log is a separate event so we don't have to encode log
    // bytes as base64. The drawer's daemon session subscribes via
    // `subscribeSidecarLogs` (export name kept stable).
    this.#unlisteners.push(
      await listen<DaemonLogEvent>("daemon-log", (e) => {
        if (this.#onDaemonLog) this.#onDaemonLog(e.payload);
      }),
    );
  }

  async stop(): Promise<void> {
    for (const un of this.#unlisteners) un();
    this.#unlisteners = [];
    this.#onOutput.clear();
    this.#onExit.clear();
    this.#onDaemonLog = null;
    this.#started = false;
  }

  async spawn(opts: SpawnOptions): Promise<string> {
    await this.ensureStarted();
    const result = await invoke<{ session_id: string }>("terminal_spawn", {
      req: opts,
    });
    return result.session_id;
  }

  subscribe(sessionId: string, onOutput: OutputHandler, onExit: ExitHandler) {
    this.#onOutput.set(sessionId, onOutput);
    this.#onExit.set(sessionId, onExit);
  }

  unsubscribe(sessionId: string) {
    this.#onOutput.delete(sessionId);
    this.#onExit.delete(sessionId);
  }

  /** Subscribe to the daemon's stdout/stderr lines (daemon-log event).
   *  Only one subscriber at a time — there's only one drawer.
   *  Export name kept stable for the UI. */
  subscribeSidecarLogs(handler: (e: DaemonLogEvent) => void): void {
    this.#onDaemonLog = handler;
  }

  unsubscribeSidecarLogs(): void {
    this.#onDaemonLog = null;
  }

  async write(sessionId: string, bytes: Uint8Array) {
    await invoke("terminal_write", {
      req: { session_id: sessionId, data: encodeB64(bytes) },
    });
  }

  async writeString(sessionId: string, s: string) {
    await this.write(sessionId, new TextEncoder().encode(s));
  }

  async resize(sessionId: string, cols: number, rows: number) {
    await invoke("terminal_resize", {
      req: { session_id: sessionId, cols, rows },
    });
  }

  async kill(sessionId: string) {
    await invoke("terminal_kill", { sessionId });
  }
}

export const terminal = new TerminalBridge();

// ── Drawer controller ─────────────────────────────────────────────
//
// Owns the session list + active selection. The Svelte component
// reads from this; other parts of the app call `runInstall`, `newShell`,
// `toggle`, etc.

export interface InstallRequest {
  command: string[];
  label: string;
}

export interface InstallResult {
  exit_code: number | null;
}

class TerminalDrawerState {
  open = $state(false);

  /** All sessions in display order. The daemon log session always sits
   *  at index 0. */
  sessions = $state<SessionMeta[]>([
    {
      id: SIDECAR_SESSION_ID,
      label: "Daemon logs",
      kind: "daemon",
      state: "running",
      exit_code: null,
      closable: false,
    },
  ]);

  /** id of the visible session. */
  activeId = $state<string>(SIDECAR_SESSION_ID);

  // Pending one-shot install — picked up by the drawer next time it
  // mounts/sees this update.
  pendingInstall = $state<InstallRequest | null>(null);
  /** Caller-side promise resolver for the pending install. */
  #pendingResolve: ((r: InstallResult) => void) | null = null;

  toggle() {
    this.open = !this.open;
  }

  show() {
    this.open = true;
  }

  hide() {
    this.open = false;
  }

  setActive(id: string) {
    if (this.sessions.find((s) => s.id === id)) this.activeId = id;
  }

  /** Drawer-internal: add a freshly-spawned session to the list. */
  registerSession(meta: SessionMeta) {
    this.sessions = [...this.sessions, meta];
    this.activeId = meta.id;
  }

  /** Drawer-internal: mark a session as exited/failed. */
  markExited(id: string, code: number | null) {
    this.sessions = this.sessions.map((s) =>
      s.id === id
        ? {
            ...s,
            state: code === 0 ? "exited" : "failed",
            exit_code: code,
          }
        : s,
    );
  }

  /** Drawer-internal: drop a session from the list (closable only). */
  removeSession(id: string) {
    const before = this.sessions.find((s) => s.id === id);
    if (!before || !before.closable) return;
    this.sessions = this.sessions.filter((s) => s.id !== id);
    if (this.activeId === id) {
      this.activeId = SIDECAR_SESSION_ID;
    }
  }

  /** Daemon status dot — updated from the daemon store's state stream
   *  (daemon-state event) by the drawer component. Export name kept
   *  stable for the UI. The early-out guard is load-bearing: the drawer
   *  calls this from a `$effect` that reads `daemonStore.status.state`.
   *  Without the guard, writing a new array reference here re-triggers
   *  the effect (sessions becomes a read-write dep) and Svelte's
   *  infinite-update guard fires. */
  setSidecarState(state: SessionMeta["state"]) {
    const current = this.sessions.find((s) => s.id === SIDECAR_SESSION_ID);
    if (!current || current.state === state) return;
    this.sessions = this.sessions.map((s) =>
      s.id === SIDECAR_SESSION_ID ? { ...s, state } : s,
    );
  }

  /** Public: request a one-shot install in a new session. Resolves
   *  with the exit code when the child exits. */
  async runInstall(req: InstallRequest): Promise<InstallResult> {
    this.open = true;
    return new Promise((resolve) => {
      this.pendingInstall = req;
      this.#pendingResolve = resolve;
    });
  }

  /** Drawer-internal: ack the pending install — drawer is about to
   *  spawn it. Resets the slot so a second runInstall doesn't double-fire.
   *
   *  We only write to `pendingInstall` when there's actually something
   *  to take. The drawer reads this from a `$effect`; writing `null`
   *  unconditionally creates a read-write dep that's a potential
   *  infinite-loop source, same shape as `setSidecarState` below. */
  takePendingInstall(): InstallRequest | null {
    const req = this.pendingInstall;
    if (req !== null) this.pendingInstall = null;
    return req;
  }

  /** Drawer-internal: resolve the runInstall promise when the child exits. */
  resolveInstall(result: InstallResult) {
    if (this.#pendingResolve) {
      const fn = this.#pendingResolve;
      this.#pendingResolve = null;
      fn(result);
    }
  }
}

export const terminalDrawer = new TerminalDrawerState();
