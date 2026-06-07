/**
 * kernel.ts — the LOCAL OQL kernel (oql.wasm, embedded in the shell). Weave /
 * tangle / validate workbooks fully in-process: no runtime, no Docker, offline.
 * This is the workbook-native core; the runtime (runtime.ts) is the optional
 * server tier for agents/sync.
 */
import { isTauri, invoke } from "./tauri";

function ensureKernel() {
  if (!isTauri()) throw new Error("the local kernel needs the desktop shell (oql.wasm)");
}

/** Org workbook → rich HTML, rendered locally by the embedded kernel. */
export async function weave(org: string): Promise<string> {
  ensureKernel();
  return invoke<string>("weave", { org });
}

/** Org → build plan (JSON): the literate workbook's WIT-world components. */
export async function tangle(org: string): Promise<unknown> {
  ensureKernel();
  return JSON.parse(await invoke<string>("tangle", { org }));
}

/** Org → validation diagnostics (JSON). */
export async function validate(org: string): Promise<unknown> {
  ensureKernel();
  return JSON.parse(await invoke<string>("validate", { org }));
}

/** Org → lint diagnostics (JSON). */
export async function lint(org: string): Promise<unknown> {
  ensureKernel();
  return JSON.parse(await invoke<string>("lint", { org }));
}

/** Org → headline outline rows (JSON) — for navigation / structure. */
export async function outline(org: string): Promise<unknown> {
  ensureKernel();
  return JSON.parse(await invoke<string>("outline", { org }));
}

/** Is the local kernel available? (true in the desktop shell.) */
export function hasLocalKernel(): boolean {
  return isTauri();
}
