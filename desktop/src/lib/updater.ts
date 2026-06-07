/**
 * updater.ts — self-update. Checks the GitHub Release `latest.json`, and if a
 * newer signed build exists, downloads + installs it and relaunches. Only runs in
 * the desktop shell; a plain SPA / browser never updates itself.
 */
import { isTauri } from "./tauri";

export interface UpdateInfo {
  available: boolean;
  version?: string;
  notes?: string;
}

/** Is an update available? (Does not install.) */
export async function checkForUpdate(): Promise<UpdateInfo> {
  if (!isTauri()) return { available: false };
  const { check } = await import("@tauri-apps/plugin-updater");
  const update = await check();
  if (!update) return { available: false };
  return { available: true, version: update.version, notes: update.body ?? undefined };
}

/**
 * Check, and if an update is available, download + install it (with optional
 * progress) and relaunch into the new version. Returns false if nothing to do.
 */
export async function installUpdate(onProgress?: (pct: number) => void): Promise<boolean> {
  if (!isTauri()) return false;
  const { check } = await import("@tauri-apps/plugin-updater");
  const update = await check();
  if (!update) return false;

  let total = 0;
  let got = 0;
  await update.downloadAndInstall((event) => {
    if (event.event === "Started") total = event.data.contentLength ?? 0;
    else if (event.event === "Progress") {
      got += event.data.chunkLength;
      if (total && onProgress) onProgress(Math.round((got / total) * 100));
    }
  });

  const { relaunch } = await import("@tauri-apps/plugin-process");
  await relaunch();
  return true;
}
