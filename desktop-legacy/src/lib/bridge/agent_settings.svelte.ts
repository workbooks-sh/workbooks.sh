// Agent defaults bridge — default model used by the oql-agent
// sidecar when no per-task override is set. Mirrors `agent_settings.rs`.
//
// The setting persists in `~/.oql/desktop/agent-settings.org` and is
// pushed into the live sidecar via /internal/secrets/refresh as
// `WB_AGENT_MODEL`, so a change here takes effect on the next agent
// call without a restart.

import { invoke } from "@tauri-apps/api/core";
import { ws } from "./ws.svelte";

export interface AgentSettings {
  default_model: string;
  /** Slug of the agent the chat panel opens to on first load (when no
   *  per-window selection has been persisted to localStorage). Empty
   *  string = unset, fall back to the catalog default. */
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
  #liveUnsub: (() => void) | null = null;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
    this.#liveUnsub = ws.onMonorepoChange("agent-settings.org", () => {
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
