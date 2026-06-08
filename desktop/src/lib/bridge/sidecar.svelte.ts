// wb-i38o.2 — sidecar status mirror.
//
// Receives the `sidecar-state` events fired by `src-tauri/src/sidecar.rs`
// and mirrors them into a Svelte 5 rune-friendly store. Components
// read `sidecar.status` reactively; the rest of the app reads
// `sidecar.url` to know where the Elixir agent is listening.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

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
  mode: "bundled" | "dev" | null;
  message: string | null;
}

const DEFAULT: SidecarStatus = {
  state: "stopped",
  url: null,
  mode: null,
  message: null,
};

class SidecarStore {
  status = $state<SidecarStatus>(DEFAULT);
  #unlisten: UnlistenFn | null = null;
  #initStarted = false;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    // Listen first so we don't miss the transition between our
    // invoke() returning the snapshot and the next emit.
    this.#unlisten = await listen<SidecarStatus>("sidecar-state", (e) => {
      this.status = e.payload;
    });
    // Pull the current snapshot in case the sidecar already booted
    // before this component mounted.
    try {
      const snap = await invoke<SidecarStatus>("sidecar_status");
      this.status = snap;
    } catch (e) {
      console.warn("[sidecar] sidecar_status invoke failed", e);
    }
  }

  destroy() {
    this.#unlisten?.();
    this.#unlisten = null;
    this.#initStarted = false;
  }
}

export const sidecar = new SidecarStore();
