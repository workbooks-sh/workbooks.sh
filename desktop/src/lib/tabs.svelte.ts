/**
 * tabs — the open-document list shown in the titlebar.
 *
 * The host (Rust) owns the canonical list so the agent can mutate it;
 * the frontend reads via `tabList` once at init, then would listen for
 * `tabs-state` events to stay synced. Mutations (open / focus / close)
 * go through the command layer and the returned snapshot is applied
 * locally.
 *
 * Mock today: `commands.*` resolve canned snapshots and `events.on` is a
 * no-op subscription. When the Tauri shell lands the only change is that
 * those two layers reach the real host — this store is unchanged.
 */

import { commands, type Tab, type TabsSnapshot } from "./bindings";
import { events } from "./ipc";

class TabsStore {
  tabs = $state<Tab[]>([]);
  activeId = $state<string | null>(null);
  #started = false;
  #unlisten: (() => void) | null = null;

  active = $derived<Tab | null>(this.tabs.find((t) => t.id === this.activeId) ?? null);

  async init() {
    if (this.#started) return;
    this.#started = true;
    this.#unlisten = events.on<TabsSnapshot>("tabs-state", (snap) => this.#apply(snap));
    try {
      this.#apply(await commands.tabList());
    } catch (e) {
      console.warn("[tabs] tabList failed", e);
    }
  }

  destroy() {
    this.#unlisten?.();
    this.#unlisten = null;
    this.#started = false;
  }

  #apply(snap: TabsSnapshot) {
    this.tabs = snap.tabs;
    this.activeId = snap.activeId;
  }

  async open(path: string) {
    this.#apply(await commands.tabOpen({ path }));
  }
  async focus(id: string) {
    this.#apply(await commands.tabFocus({ id }));
  }
  async close(id: string) {
    this.#apply(await commands.tabClose({ id }));
  }
}

export const tabs = new TabsStore();
