// wb-i38o.8 — tabs store, mirrors the Rust-owned canonical list.
//
// The host owns the truth (so the agent can mutate it in wb-i38o.11);
// the frontend reads via `tab_list` once at init, then listens for
// `tabs-state` events to stay synced. UI actions (open / focus /
// close) go through Tauri invokes; the resulting snapshot is
// applied locally on success AND re-broadcast via event for any
// other listener that might exist.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { Tab, TabsSnapshot } from "./types";

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

  #apply(snap: TabsSnapshot) {
    this.tabs = snap.tabs;
    this.activeId = snap.active;
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

  /** wb-i38o.11 — close-by-path helper for the agent control bridge.
   *  Resolves path → id against the current snapshot. Silent no-op
   *  if no tab matches (matches Elixir-side semantics: agent told us
   *  to close, the user already closed it — both fine). */
  async closeByPath(path: string): Promise<boolean> {
    const t = this.tabs.find((tab) => tab.path === path);
    if (!t) return false;
    await this.close(t.id);
    return true;
  }

  /** wb-i38o.11 — focus-by-path helper. Returns false if no tab
   *  matches; the agent should call open() instead for create-or-focus. */
  async focusByPath(path: string): Promise<boolean> {
    const t = this.tabs.find((tab) => tab.path === path);
    if (!t) return false;
    await this.focus(t.id);
    return true;
  }
}

export const tabs = new TabsStore();
