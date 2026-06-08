// Lifecycle bridge — daemon provision/teardown.
//
// Phase B: the legacy `engine_*` commands collapsed into the canonical
// `daemon_*` surface (daemon.rs). This module keeps its EXPORTED names
// stable (the onboarding splash + +page.svelte import them) but its
// bodies now invoke() the new native daemon commands. There is ONE
// daemon store now (`daemon` in `./sidecar.svelte`); this file is the thin
// install/teardown verb pair the onboarding flow drives.
//
// NATIVE / offline: every call here is a Rust shell command.

import { invoke } from "@tauri-apps/api/core";
import type { DaemonStatus } from "./sidecar.svelte";

/** Back-compat view the onboarding UI reads: `.state` + `.installed`.
 *  Derived from the native DaemonStatus (running|unhealthy|stopped). */
export interface EngineStatus {
  state: "running" | "stopped" | "unhealthy" | "unknown";
  url: string | null;
  pid: number | null;
  installed: boolean;
}

function toEngineStatus(d: DaemonStatus): EngineStatus {
  return {
    state: d.state,
    url: d.url || null,
    pid: d.pid || null,
    // "installed" == the daemon has ever reported a URL (running/unhealthy
    // both mean a discovery file exists, i.e. it's provisioned).
    installed: d.state === "running" || d.state === "unhealthy",
  };
}

/** Liveness snapshot. Backed by native `daemon_status`. */
export async function engineStatus(): Promise<EngineStatus> {
  return toEngineStatus(await invoke<DaemonStatus>("daemon_status"));
}

/** Provision + boot the daemon. Aliased to `daemon_up`. */
export async function engineInstall(): Promise<void> {
  await invoke<DaemonStatus>("daemon_up");
}

/** Tear the daemon down. Aliased to `daemon_down`. */
export async function engineUninstall(): Promise<void> {
  await invoke<DaemonStatus>("daemon_down");
}
