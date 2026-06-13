// Open-intent consumer (wb-aakl.10) — the browser side of `wb desktop
// open <path|url>`.
//
// The CLI drops an open-intent file at <dataDir>/sh.workbooks/disco/
// open-intent.json (mirroring daemon.rs discovery_path). This watcher reads
// it on boot and on every window focus, opens the target as a tab, then
// clears it. Focus coverage means a SECOND `wb desktop open <path>` against
// the already-running browser lands too — a dependency-free deep link, no
// URL scheme to register and no Tauri plugin.
//
// Fully guarded: in the browser preview (no Tauri path/fs) every call
// no-ops, so this is safe to mount unconditionally.

import { invoke } from "@tauri-apps/api/core";
import { dataDir, join } from "@tauri-apps/api/path";
import { tabs } from "$lib/tabs/store.svelte";

let intentPath: string | null = null;
let started = false;

async function resolvePath(): Promise<string | null> {
  if (intentPath) return intentPath;
  try {
    const base = await dataDir(); // ~/Library/Application Support on macOS
    intentPath = await join(base, "sh.workbooks", "disco", "open-intent.json");
    return intentPath;
  } catch {
    return null; // no Tauri path API (browser preview)
  }
}

async function check(): Promise<void> {
  const path = await resolvePath();
  if (!path) return;

  let raw: string;
  try {
    raw = await invoke<string>("fs_read_file", { path });
  } catch {
    return; // no intent file pending
  }
  if (!raw || !raw.trim()) return;

  let target: string | null = null;
  try {
    const parsed = JSON.parse(raw);
    target = typeof parsed?.target === "string" ? parsed.target : null;
  } catch {
    /* malformed — fall through to clear it */
  }

  // Clear FIRST so a failed open doesn't replay the same intent on the next
  // focus. Best-effort: a write failure just means we retry next focus.
  try {
    await invoke("fs_write_file", { path, content: "" });
  } catch {
    /* ignore */
  }

  if (!target) return;
  try {
    await tabs.open(target);
  } catch (e) {
    console.warn("[open-intent] failed to open", target, e);
  }
}

export const openIntent = {
  /** Check once now, then on every window focus. Idempotent. */
  watch(): void {
    if (started) return;
    started = true;
    void check();
    if (typeof window !== "undefined") {
      window.addEventListener("focus", () => void check());
    }
  },
};
