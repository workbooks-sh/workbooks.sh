/**
 * runtime.ts — the client to the Workbooks RUNTIME (the BEAM engine the shell's
 * daemon brought up). This is how the frontend gets DATA: authenticated HTTP/WS
 * to the discovered localhost URL — NOT Rust IPC (the shell only bridges native
 * things: the runtime URL/token, daemon lifecycle, tray, keychain).
 *
 * In a plain SPA (no shell) there is no runtime — callers should fall back to the
 * mock `commands` in bindings.ts. `getRuntime().state === "spa"` signals that.
 */
import { isTauri, invoke } from "./tauri";

export interface RuntimeInfo {
  url: string;
  token: string;
  state: string; // "up" | "down" | "spa"
}

let cached: RuntimeInfo | null = null;

/** The runtime's discovered URL + per-boot bearer token (from the shell). */
export async function getRuntime(force = false): Promise<RuntimeInfo> {
  if (!isTauri()) return { url: "", token: "", state: "spa" };
  if (cached && !force) return cached;
  cached = await invoke<RuntimeInfo>("runtime_url");
  return cached;
}

/** Authenticated fetch against the runtime control plane. Throws if no runtime. */
export async function rt(path: string, init: RequestInit = {}): Promise<Response> {
  const info = await getRuntime();
  if (!info.url) throw new Error("runtime not available (no desktop shell / daemon down)");
  const headers = new Headers(init.headers);
  if (info.token) headers.set("authorization", `Bearer ${info.token}`);
  return fetch(`${info.url}${path}`, { ...init, headers });
}

/** Convenience: GET + parse JSON from the runtime. */
export async function rtJson<T>(path: string): Promise<T> {
  const res = await rt(path);
  if (!res.ok) throw new Error(`runtime ${path} → HTTP ${res.status}`);
  return (await res.json()) as T;
}

/** Daemon lifecycle (native side — the deploy-kit, via the shell). */
export const daemon = {
  status: () => invoke<string>("daemon_status"),
  up: () => invoke<string>("daemon_up"),
  down: () => invoke<string>("daemon_down"),
};
