// Lifecycle bridge — the ONE daemon status store.
//
// Phase B collapses the old engine + sidecar stores into a single
// daemon mirror backed by daemon.rs. The native command is
// `daemon_status` and the event is `daemon-state` (full DaemonStatus
// payload, not a bare string). This file keeps the EXPORTED `sidecar`
// store + `SidecarState`/`SidecarStatus` type names stable — the whole
// UI reads `sidecar.status.{state,url}` — while wiring the bodies to
// the new native surface. `daemon` is exported as the canonical alias.
//
// NATIVE / offline: status is a local Rust probe (discovery + /health),
// so the chip resolves a concrete state even with the runtime down.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

/** Native daemon health view (matches daemon.rs DaemonStatus, camelCase
 *  serde). `token` is the per-boot bearer the runtime transport attaches. */
export interface DaemonStatus {
  state: "running" | "stopped" | "unhealthy" | "unknown";
  url: string;
  pid: number;
  token: string;
  /** Who manages the runtime: "container" (tray-owned, restartable) or "raw"
   *  (hand-launched dev runtime the tray won't touch). "" when down. */
  manager: "container" | "raw" | "";
}

// Back-compat vocabulary the UI's status chip + STATE_TONE/STATE_LABEL
// maps were written against. The native daemon only emits
// running|stopped|unhealthy; the extra members are kept so existing
// `=== "ready"` / `=== "crashed"` comparisons still type-check. We map
// native → this vocabulary in #fromDaemon (running→ready).
export type SidecarState =
  | "starting"
  | "ready"
  | "unhealthy"
  | "crashed"
  | "restarting"
  | "stopped";

export interface SidecarStatus {
  state: SidecarState;
  url: string | null;
  /** Per-boot bearer token from discovery (empty when down). */
  token: string | null;
  mode: "bundled" | "dev" | null;
  message: string | null;
}

const DEFAULT: SidecarStatus = {
  state: "stopped",
  url: null,
  token: null,
  mode: null,
  message: null,
};

/** Map the native daemon vocabulary onto the UI's SidecarState. */
function fromDaemon(d: DaemonStatus): SidecarStatus {
  const state: SidecarState =
    d.state === "running"
      ? "ready"
      : d.state === "unhealthy"
        ? "unhealthy"
        : "stopped";
  return {
    state,
    url: d.url || null,
    token: d.token || null,
    mode: d.manager === "raw" ? "dev" : d.manager === "container" ? "bundled" : null,
    message: null,
  };
}

class DaemonStore {
  status = $state<SidecarStatus>(DEFAULT);
  #unlisten: UnlistenFn | null = null;
  #initStarted = false;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    // Listen first so we don't miss the transition between the invoke()
    // snapshot below and the next poll emit (~3s, daemon::spawn_state_poll).
    this.#unlisten = await listen<DaemonStatus>("daemon-state", (e) => {
      this.status = fromDaemon(e.payload);
    });
    // Pull the current snapshot in case the daemon already booted before
    // this component mounted.
    try {
      const snap = await invoke<DaemonStatus>("daemon_status");
      this.status = fromDaemon(snap);
    } catch (e) {
      console.warn("[daemon] daemon_status invoke failed", e);
    }
  }

  /** Boot the daemon (provision + start). Refreshes the mirror. */
  async up(): Promise<void> {
    const snap = await invoke<DaemonStatus>("daemon_up");
    this.status = fromDaemon(snap);
  }

  /** Stop the daemon. Refreshes the mirror. */
  async down(): Promise<void> {
    const snap = await invoke<DaemonStatus>("daemon_down");
    this.status = fromDaemon(snap);
  }

  /** Restart the daemon (down → up, waits for discovery). */
  async restart(): Promise<void> {
    const snap = await invoke<DaemonStatus>("daemon_restart");
    this.status = fromDaemon(snap);
  }

  destroy() {
    this.#unlisten?.();
    this.#unlisten = null;
    this.#initStarted = false;
  }
}

/** Canonical lifecycle store. */
export const daemon = new DaemonStore();

/** Back-compat alias — the UI imports `sidecar`; it IS the daemon store. */
export const sidecar = daemon;
