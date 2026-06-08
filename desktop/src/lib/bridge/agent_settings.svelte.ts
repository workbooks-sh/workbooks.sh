// Agent defaults bridge — NATIVE/local cap (offline-capable).
//
// `default_model` is the model the runtime agent tier uses when no
// per-task override is set; `default_agent_slug` pins which agent the
// chat panel opens to on first load. Both persist host-side via the
// Rust shell (agent_settings_get / agent_settings_set) so the values
// survive offline and across restarts.
//
// agent_settings_set is best-effort on the runtime side: when the
// daemon is up the shell also pushes the new model down the live
// control-plane (so a change takes effect without a daemon restart);
// when offline it just persists locally and the next daemon boot
// picks it up. Either way the returned AgentSettings is authoritative
// for the UI.

import { invoke } from "@tauri-apps/api/core";

export interface AgentSettings {
  default_model: string;
  /** Slug of the agent the chat panel opens to on first load (when no
   *  per-window selection has been persisted locally). Empty string =
   *  unset, fall back to the catalog default. */
  default_agent_slug: string;
}

interface AgentSettingsUpdate {
  default_model?: string;
  default_agent_slug?: string;
}

class AgentSettingsStore {
  settings = $state<AgentSettings>({
    default_model: "",
    default_agent_slug: "",
  });
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
  }

  dispose() {
    // No live subscription to tear down — settings are local-native and
    // refreshed directly after each mutation.
  }

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      this.settings = await invoke<AgentSettings>("agent_settings_get");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async setModel(default_model: string): Promise<void> {
    this.settings = await invoke<AgentSettings>("agent_settings_set", {
      req: { default_model } satisfies AgentSettingsUpdate,
    });
  }

  /** Pin (or clear, with empty string) the default agent slug. */
  async setDefaultAgent(default_agent_slug: string): Promise<void> {
    this.settings = await invoke<AgentSettings>("agent_settings_set", {
      req: { default_agent_slug } satisfies AgentSettingsUpdate,
    });
  }
}

export const agentSettings = new AgentSettingsStore();
