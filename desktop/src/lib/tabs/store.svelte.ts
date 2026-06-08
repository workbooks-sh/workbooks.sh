// files domain — tabs store (Phase B). Native tab_* commands +
// local-store (tabs.json) persistence.
//
// The host owns the truth (so the agent can mutate it); the frontend
// reads via `tab_list` once at init, then listens for `tabs-state`
// events to stay synced. UI actions (open / focus / close) go through
// native Tauri invokes; the resulting snapshot is applied locally on
// success.
//
// LOCKED serde contract: TabsSnapshot serializes `active` (the active
// tab id), matching tabs/types.ts. We read `snap.active` directly — no
// `activeId` field on the wire.
//
// local-store: the last snapshot is mirrored into tabs.json (plugin-
// store) so the tab strip can rehydrate instantly at boot — before the
// host's first `tab_list` resolves — and survives a cold start. The host
// snapshot remains authoritative and reconciles over the cached one.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { LazyStore } from "@tauri-apps/plugin-store";
import type { Tab, TabsSnapshot } from "./types";

const STORE_FILE = "tabs.json";
const SNAPSHOT_KEY = "snapshot";

/** Lazily-opened plugin-store. autoSave off — we persist explicitly
 *  after each apply so a reload always reads a settled file. */
const store = new LazyStore(STORE_FILE, { autoSave: false });

class TabsStore {
  tabs = $state<Tab[]>([]);
  activeId = $state<string | null>(null);
  #unlisten: UnlistenFn | null = null;
  #initStarted = false;

  active = $derived<Tab | null>(
    this.tabs.find((t) => t.id === this.activeId) ?? null,
  );

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;

    // Optimistic rehydrate from the local-store cache so the strip
    // paints immediately. Best-effort: a missing/corrupt file is fine.
    try {
      const cached = await store.get<TabsSnapshot>(SNAPSHOT_KEY);
      if (cached && Array.isArray(cached.tabs)) this.#apply(cached, false);
    } catch (err) {
      console.warn("[tabs] cache rehydrate failed", err);
    }

    this.#unlisten = await listen<TabsSnapshot>("tabs-state", (e) => {
      this.#apply(e.payload);
    });
    try {
      const snap = await invoke<TabsSnapshot>("tab_list");
      this.#apply(snap);
    } catch (err) {
      console.warn("[tabs] tab_list invoke failed", err);
    }
  }

  destroy() {
    this.#unlisten?.();
    this.#unlisten = null;
    this.#initStarted = false;
  }

  #apply(snap: TabsSnapshot, persist = true) {
    this.tabs = snap.tabs;
    this.activeId = snap.active;
    if (persist) void this.#persist(snap);
  }

  async #persist(snap: TabsSnapshot): Promise<void> {
    try {
      await store.set(SNAPSHOT_KEY, snap);
      await store.save();
    } catch (err) {
      console.warn("[tabs] persist failed", err);
    }
  }

  async open(path: string): Promise<void> {
    const snap = await invoke<TabsSnapshot>("tab_open", { path });
    this.#apply(snap);
  }

  async close(id: string): Promise<void> {
    const snap = await invoke<TabsSnapshot>("tab_close", { id });
    this.#apply(snap);
  }

  async focus(id: string): Promise<void> {
    const snap = await invoke<TabsSnapshot>("tab_focus", { id });
    this.#apply(snap);
  }

  /** Mark a tab dirty/clean. Native command returns void; we update the
   *  local copy optimistically and persist. */
  async setDirty(id: string, dirty: boolean): Promise<void> {
    await invoke("tab_set_dirty", { id, dirty });
    const next = this.tabs.map((t) => (t.id === id ? { ...t, dirty } : t));
    this.#apply({ tabs: next, active: this.activeId });
  }

  /** Close-by-path helper for the agent control bridge. Resolves
   *  path → id against the current snapshot. Silent no-op if no tab
   *  matches (matches host-side semantics: agent told us to close, the
   *  user already closed it — both fine). */
  async closeByPath(path: string): Promise<boolean> {
    const t = this.tabs.find((tab) => tab.path === path);
    if (!t) return false;
    await this.close(t.id);
    return true;
  }

  /** Focus-by-path helper. Returns false if no tab matches; the caller
   *  should call open() instead for create-or-focus. */
  async focusByPath(path: string): Promise<boolean> {
    const t = this.tabs.find((tab) => tab.path === path);
    if (!t) return false;
    await this.focus(t.id);
    return true;
  }
}

export const tabs = new TabsStore();
