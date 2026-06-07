/**
 * Persistent store — SHAPED for the @tauri-apps/plugin-store interface
 * so the real plugin drops in when the Tauri shell lands.
 *
 * The plugin's `Store` exposes async `get`/`set`/`save`/`onKeyChange`.
 * We mirror that surface here, backed by `localStorage` (or an
 * in-memory map when localStorage is unavailable, e.g. SSR/build),
 * so the app builds + runs as a plain Vite SPA today.
 *
 * TODO(tauri-shell): replace the body with
 *   `import { Store } from "@tauri-apps/plugin-store";`
 *   `const store = await Store.load("settings.json");`
 * and forward get/set/onKeyChange to it. The interface below is the
 * contract callers depend on — keep it stable across that swap.
 */

type Unsubscribe = () => void;
type KeyListener<T> = (value: T | undefined) => void;

export interface PersistentStore {
  get<T>(key: string): Promise<T | undefined>;
  set<T>(key: string, value: T): Promise<void>;
  /** Reactive subscribe — fires immediately with the current value,
   *  then on every subsequent `set` to the same key. */
  subscribe<T>(key: string, fn: KeyListener<T>): Unsubscribe;
}

const NS = "workbooks:";
const mem = new Map<string, string>();
const listeners = new Map<string, Set<KeyListener<unknown>>>();

function hasLocal(): boolean {
  try {
    return typeof localStorage !== "undefined";
  } catch {
    return false;
  }
}

function readRaw(key: string): string | null {
  return hasLocal() ? localStorage.getItem(NS + key) : (mem.get(key) ?? null);
}

function writeRaw(key: string, raw: string): void {
  if (hasLocal()) localStorage.setItem(NS + key, raw);
  else mem.set(key, raw);
}

class MockStore implements PersistentStore {
  async get<T>(key: string): Promise<T | undefined> {
    const raw = readRaw(key);
    if (raw == null) return undefined;
    try {
      return JSON.parse(raw) as T;
    } catch {
      return undefined;
    }
  }

  async set<T>(key: string, value: T): Promise<void> {
    writeRaw(key, JSON.stringify(value));
    const set = listeners.get(key);
    if (set) for (const fn of set) fn(value);
  }

  subscribe<T>(key: string, fn: KeyListener<T>): Unsubscribe {
    let set = listeners.get(key) as Set<KeyListener<unknown>> | undefined;
    if (!set) {
      set = new Set();
      listeners.set(key, set);
    }
    set.add(fn as KeyListener<unknown>);
    // Immediate replay of the current value.
    void this.get<T>(key).then((v) => fn(v));
    return () => set!.delete(fn as KeyListener<unknown>);
  }
}

export const store: PersistentStore = new MockStore();
