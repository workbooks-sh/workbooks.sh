// wb-i38o.6 §3 — Plugin registry store.
//
// UI-only persistence today; agent-side plugin loading is OUT OF SCOPE
// for v1 of this ticket.

import { invoke } from "@tauri-apps/api/core";
import { ws } from "./ws.svelte";

export interface Plugin {
  id: string;
  name: string;
  source: string;
  version: string;
  enabled: boolean;
  installed_at: number;
}

export interface PluginCreate {
  name: string;
  source: string;
  version: string;
  enabled: boolean;
}

class PluginsStore {
  plugins = $state<Plugin[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;
  #liveUnsub: (() => void) | null = null;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
    this.#liveUnsub = ws.onMonorepoChange("plugins.org", () => {
      void this.refresh();
    });
  }

  dispose() {
    this.#liveUnsub?.();
    this.#liveUnsub = null;
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      this.plugins = await invoke<Plugin[]>("plugins_list");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async install(req: PluginCreate): Promise<Plugin> {
    const p = await invoke<Plugin>("plugins_install", { req });
    await this.refresh();
    return p;
  }

  async setEnabled(id: string, enabled: boolean): Promise<void> {
    await invoke("plugins_set_enabled", { req: { id, enabled } });
    await this.refresh();
  }

  async remove(id: string): Promise<void> {
    await invoke("plugins_remove", { id });
    await this.refresh();
  }
}

export const plugins = new PluginsStore();
