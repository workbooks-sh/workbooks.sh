// wb-8285 — SKILL.md catalog store.
//
// Mirrors Workbooks.Engine.SkillCatalog (Anthropic-convention SKILL.md
// discovery). Distinct from `skills.svelte.ts` which tracks the
// integration-mediated skill bundles (Composio, Claude Code, ...).
//
// Hits GET /api/skills lazily on first access; caches the result
// for the session. Used by the chat compose's @-picker.

import { sidecar } from "$lib/bridge/sidecar.svelte";
import { packageStore as workspace } from "$lib/bridge/package.svelte";

export interface SkillMdEntry {
  slug: string;
  name: string;
  description: string | null;
  source: "project" | "workspace" | "user";
}

class SkillCatalogStore {
  entries = $state<SkillMdEntry[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #loaded = false;

  async ensureLoaded(): Promise<void> {
    if (this.#loaded || this.loading) return;
    await this.refresh();
  }

  async refresh(): Promise<void> {
    if (!sidecar.status.url) {
      this.lastError = "Agent server isn't running.";
      return;
    }
    this.loading = true;
    this.lastError = null;
    try {
      const ws = workspace.active?.folders?.[0];
      const qs = ws ? `?workspace=${encodeURIComponent(ws)}` : "";
      const res = await fetch(`${sidecar.status.url}/api/skills${qs}`, {
        headers: { accept: "application/json" },
      });
      if (!res.ok) {
        this.lastError = `GET /api/skills returned ${res.status}`;
        return;
      }
      const body = (await res.json().catch(() => null)) as
        | { skills?: SkillMdEntry[] }
        | null;
      this.entries = Array.isArray(body?.skills) ? body.skills : [];
      this.#loaded = true;
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }
}

export const skillCatalog = new SkillCatalogStore();
