// Phase B — SKILL.md catalog store (runtime, graceful-offline).
//
// Mirrors the runtime SkillCatalog (Anthropic-convention SKILL.md
// discovery). Distinct from `skills.svelte.ts` which tracks the
// integration-mediated skill bundles (Composio, Claude Code, ...).
//
// Hits GET /api/skills lazily on first access; caches the result for
// the session. Used by the chat compose's @-picker. When the daemon is
// offline the catalog degrades to empty rather than throwing — the
// @-picker simply shows nothing.

import {
  engineRequest,
  EngineApiError,
} from "$lib/engine-api/gen";
import { packageStore as workspace } from "$lib/bridge/package.svelte";

export interface SkillMdEntry {
  slug: string;
  name: string;
  description: string | null;
  source: "project" | "workspace" | "user";
}

/** True when the failure is "the optional runtime tier isn't running".
 *  Tolerates both the new `daemon_down` code and the legacy `sidecar_down`
 *  the transport may still emit until gen.ts is renamed. */
function isDaemonDown(e: unknown): boolean {
  return (
    e instanceof EngineApiError &&
    (e.code === "daemon_down" || e.code === "sidecar_down")
  );
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
    this.loading = true;
    this.lastError = null;
    try {
      const ws = workspace.active?.folders?.[0];
      const query = ws ? `?workspace=${encodeURIComponent(ws)}` : "";
      const body = await engineRequest<{ skills?: SkillMdEntry[] }>(
        "/api/skills",
        { query },
      );
      this.entries = Array.isArray(body?.skills) ? body.skills : [];
      this.#loaded = true;
    } catch (e) {
      if (isDaemonDown(e)) {
        // Offline: empty catalog, no error surfaced to the UI.
        this.entries = [];
        return;
      }
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }
}

export const skillCatalog = new SkillCatalogStore();
