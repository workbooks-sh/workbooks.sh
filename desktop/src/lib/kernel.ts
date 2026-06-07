/**
 * kernel.ts — the LOCAL OQL kernel (oql.wasm, embedded in the shell). Weave /
 * tangle / validate workbooks fully in-process: no runtime, no Docker, offline.
 * This is the workbook-native core; the runtime (runtime.ts) is the optional
 * server tier for agents/sync.
 */
import { isTauri, invoke } from "./tauri";

/** Org workbook → rich HTML, rendered locally by the embedded kernel. */
export async function weave(org: string): Promise<string> {
  if (!isTauri()) throw new Error("local weave needs the desktop shell (oql.wasm)");
  return invoke<string>("weave", { org });
}

/** Is the local kernel available? (true in the desktop shell.) */
export function hasLocalKernel(): boolean {
  return isTauri();
}
