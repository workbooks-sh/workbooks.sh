// Frontend bridge for the launchd-managed oql-agent daemon.
// Backed by `apps/desktop/src-tauri/src/engine.rs`, which shells
// out to the oql-agent binary's CLI subcommands.
//
// The desktop is the only supported install path — we do not
// expect users to install via terminal. The splash in
// `lib/setup/EngineOnboarding.svelte` is the canonical UX.

import { invoke } from "@tauri-apps/api/core";

export interface EngineStatus {
  state: "running" | "stopped" | "stale" | "unknown";
  url: string | null;
  pid: number | null;
  installed: boolean;
}

export async function engineStatus(): Promise<EngineStatus> {
  return await invoke<EngineStatus>("engine_status");
}

export async function engineInstall(): Promise<void> {
  return await invoke<void>("engine_install");
}

export async function engineUninstall(): Promise<void> {
  return await invoke<void>("engine_uninstall");
}
