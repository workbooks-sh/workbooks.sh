/**
 * files.ts — workbook file open/save, a NATIVE capability the shell provides.
 * The dialog plugin picks a path (main-thread safe); the read/write is a plain
 * Rust command. Part of "shell = capabilities" — the workbook-native editor
 * persists `.org` files with no runtime.
 */
import { isTauri, invoke } from "./tauri";

const ORG_FILTER = [{ name: "Org", extensions: ["org"] }];

/** Read a file by path (host fs). Used by the doc surface to load the active tab. */
export async function readFileText(path: string): Promise<string> {
  return invoke<string>("read_file", { path });
}

export interface DirEntry {
  name: string;
  path: string;
  isDir: boolean;
}

/** List a directory's immediate children (dirs first). The file-tree explorer
 *  calls this lazily per folder as it expands. */
export async function listDir(path: string): Promise<DirEntry[]> {
  if (!isTauri()) return [];
  return invoke<DirEntry[]>("read_dir", { path });
}

/** Prompt for a folder to open as the explorer root. Returns the path or null. */
export async function pickFolderPath(): Promise<string | null> {
  if (!isTauri()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const path = await open({ directory: true });
  return typeof path === "string" ? path : null;
}

/** Prompt for a workbook/file path (no read). Returns the chosen path or null.
 *  Broader than `.org` so the tab/doc surface can open any text file. */
export async function pickFilePath(): Promise<string | null> {
  if (!isTauri()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const path = await open({
    filters: [
      { name: "Workbook / text", extensions: ["org", "md", "txt", "json", "toml", "rs", "ts", "js", "py"] },
      { name: "All files", extensions: ["*"] },
    ],
  });
  return typeof path === "string" ? path : null;
}

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
