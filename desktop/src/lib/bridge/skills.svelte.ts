// Phase B — Skills bridge (local-store config file).
//
// Skills are agent-callable capability bundles (Composio actions,
// Claude Code invoke, etc.). The registry tracks which are installed
// and what scope they apply at (User / Workspace / Package), persisted
// to the local config file. The daemon reads it at agent-invocation
// time to compose the active tool set.

import { invoke } from "@tauri-apps/api/core";

export type SkillScope = "user" | "workspace" | "package";

export interface Skill {
  id: string;
  name: string;
  description: string;
  /** Origin service slug ("composio", "claude_code", …) or "manual". */
  source: string;
  /** Underlying Composio app slug when applicable. */
  app: string | null;
  scope: SkillScope;
  workspace_id: string | null;
  package_name: string | null;
  skill_md_path: string | null;
  created_at: number;
}

export interface SkillScopeUpdate {
  id: string;
  scope: SkillScope;
  workspace_id?: string;
  package_name?: string;
}

class SkillsStore {
  skills = $state<Skill[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
  }

  dispose() {}

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      this.skills = await invoke<Skill[]>("skills_list");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async setScope(req: SkillScopeUpdate): Promise<void> {
    await invoke("skills_set_scope", { req });
    await this.refresh();
  }

  async remove(id: string): Promise<void> {
    await invoke("skills_delete", { id });
    await this.refresh();
  }
}

export const skills = new SkillsStore();
