/**
 * tauri.ts — the bridge to the native shell. Present ONLY when running inside the
 * Tauri desktop shell; in a plain Vite SPA build `isTauri()` is false and these
 * are never called, so the SAME frontend runs both places (browser + desktop).
 *
 * @tauri-apps/api is imported DYNAMICALLY so the SPA bundle never hard-depends on
 * the shell being present.
 */

export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Call a Rust `#[tauri::command]`. */
export async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

/** Subscribe to a Tauri event; resolves to an unsubscribe fn. */
export async function listen<T>(event: string, fn: (payload: T) => void): Promise<() => void> {
  const { listen } = await import("@tauri-apps/api/event");
  return listen<T>(event, (e) => fn(e.payload as T));
}
