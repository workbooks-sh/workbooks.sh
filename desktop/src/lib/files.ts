/**
 * files.ts — workbook file open/save, a NATIVE capability the shell provides.
 * The dialog plugin picks a path (main-thread safe); the read/write is a plain
 * Rust command. Part of "shell = capabilities" — the workbook-native editor
 * persists `.org` files with no runtime.
 */
import { isTauri, invoke } from "./tauri";

const ORG_FILTER = [{ name: "Org", extensions: ["org"] }];

/** Open a .org workbook → its path + contents (or null if cancelled / no shell). */
export async function openWorkbook(): Promise<{ path: string; org: string } | null> {
  if (!isTauri()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const path = await open({ filters: ORG_FILTER });
  if (typeof path !== "string") return null;
  const org = await invoke<string>("read_file", { path });
  return { path, org };
}

/** Save Org to `path`, or prompt for one. Returns the path written (or null). */
export async function saveWorkbook(org: string, path?: string): Promise<string | null> {
  if (!isTauri()) return null;
  let target = path;
  if (!target) {
    const { save } = await import("@tauri-apps/plugin-dialog");
    const chosen = await save({ defaultPath: "workbook.org", filters: ORG_FILTER });
    if (typeof chosen !== "string") return null;
    target = chosen;
  }
  await invoke("write_file", { path: target, content: org });
  return target;
}
