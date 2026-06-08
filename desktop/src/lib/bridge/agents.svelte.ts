// Agents bridge — catalog + selection state.
//
// Catalog (RUNTIME cap, graceful-offline): fetched from the runtime
// control-plane GET /api/agents, which walks project-scope →
// user-scope → bundled priv/agents and returns parsed metadata per
// the :agent: entity binding (see packages/oql/plugins/agent/
// manifest.org). When the daemon is offline (or the route is still
// pending) the catalog degrades to empty — the picker renders its
// empty state, never an error.
//
// Selection (LOCAL-STORE cap, offline): which agent the chat panel
// sends to. Persists across reloads via the local agent_selection
// store (localStorage today). When the catalog has no match for the
// stored slug (deleted agent, rebuild), falls back to "workhorse" if
// present, else the first listed entry.
//
// CRUD: user-scope create/update/delete writes go through the Tauri
// shell (deferred — for v1 the manual create + edit paths use the
// `agent_define` backend tool via the creator agent, and the
// OrgEditor for in-place edits).

import {
  EngineApiError,
  enginePath,
  engineRequest,
} from "$lib/engine-api/gen";
import { packageStore as workspace } from "./package.svelte";
import { agentSettings } from "./agent_settings.svelte";
import { active } from "./_active.svelte";

export type AgentScope = "project" | "user" | "builtin";

export interface AgentCatalogEntry {
  slug: string;
  path: string;
  scope: AgentScope;
  title?: string;
  model?: string | null;
  /** High-level capability badges declared on the agent via the
   *  `:TOOLKITS:` org property (bash, wb, git, lua, …). The canonical
   *  user-facing "this agent can do X" surface — drives the
   *  capability chip in the agent picker. */
  toolkits?: string[];
  /** Transitional alias for `toolkits` — backend still emits during
   *  the wb-1nbj migration. Drop once the engine binary that emits
   *  only `toolkits` lands. */
  packages?: string[];
  /** Exact ToolRegistry allowlist (`:TOOLS:` property). Empty/absent
   *  = full catalog. Surfaced in the agent settings view as the
   *  technical detail; not used by the capability chip. */
  tools?: string[];
  /** Coarse-grained capability tags (`:CAPABILITIES:` property)
   *  used by the orchestrator for routing matches. Distinct from
   *  `toolkits` (CLI binaries) and `tools` (registry allowlist). */
  capabilities?: string[];
  max_children?: number;
  allow_spawn?: boolean;
  spawn_depth?: number;
  can_grant?: string[];
  /** Visual identity per the :agent: entity binding's :ICON: property.
   *  Formats: "emoji:<glyph>", "lucide:<IconName>", "hidden" (suppresses
   *  the agent from the picker), or null/absent (UI falls back to
   *  initials). */
  icon?: string | null;
  /** One-line human description per the :agent: binding's :TAGLINE:
   *  property. Rendered as muted subtext under the title in the
   *  agent picker + cards. */
  tagline?: string | null;
  system_prompt_preview?: string | null;
  hash?: string;
  /** Present when the .org could not be parsed. UI surfaces this. */
  parse_error?: string;
  /** Slug of the enclosing `:agent:` headline within the same .org
   *  file. `null` (or absent) for file-top-level agents. The picker
   *  uses this to render in-file children under their parent agent
   *  row. */
  parent_id?: string | null;
  /** Slash-joined directory path from the scope's `agents/` root to
   *  the .org file, excluding filename. Empty string when the file
   *  lives directly under `agents/`. The picker uses this to group
   *  agents under collapsible folder nodes. */
  folder?: string;
}

/** Bundled fixtures the daemon ships in priv/agents/ that aren't
 *  real user-facing agents in the desktop. Filtered from the catalog
 *  the picker consumes. Transitional — once the running daemon picks
 *  up the upstream removal (priv/agents no longer ships these files),
 *  the catalog won't include them and this set becomes a no-op.
 *
 *  - import-helper / lua-helper / shell-helper: legacy test agents,
 *    source removed in b0f9c4b
 *  - agent-creator: was a separate "creator agent" experiment;
 *    folded into Workhorse (source removed in this commit). The
 *    daemon still bundles it until the engine rebuilds. */
const HIDDEN_BUILTINS = new Set([
  "import-helper",
  "lua-helper",
  "shell-helper",
  "agent-creator",
]);

/** Transitional fallback icons for built-in agents whose `icon` field
 *  isn't in the catalog response yet (the running daemon may be on a
 *  pre-enrichment build). Drop when the daemon ships the
 *  api_controller.ex enrichment that surfaces :ICON:. */
const FALLBACK_ICONS: Record<string, string> = {
  workhorse: "lucide:Bot",
};

/** Same shape as FALLBACK_ICONS but for taglines — until the daemon's
 *  enrich_agent_entry surfaces :TAGLINE:. */
const FALLBACK_TAGLINES: Record<string, string> = {
  workhorse:
    "The default Workbooks agent — knows the ecosystem, can do anything reasonable.",
};

/** Local-store (agent_selection) key for the user's last-chosen
 *  agent. Offline-capable — survives with no daemon. */
const SELECTION_KEY = "wb.chat.selected-agent";

/** Fallback when the stored slug doesn't resolve in the catalog. */
const PRIMARY_FALLBACK = "workhorse";

class AgentsStore {
  agents = $state<AgentCatalogEntry[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  /** Slug the chat panel currently sends to. */
  selected = $state<string | null>(null);

  /** The entry for the selected slug, or null if no match. */
  selectedEntry = $derived<AgentCatalogEntry | null>(
    this.selected
      ? this.agents.find((a) => a.slug === this.selected) ?? null
      : null,
  );

  #initStarted = false;

  init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    // Restore selection from the local agent_selection store first so
    // the picker UI shows the right value even before the catalog
    // fetch resolves.
    try {
      const stored = localStorage.getItem(SELECTION_KEY);
      if (stored) {
        this.selected = stored;
        active.agentSlug = stored;
      }
    } catch {
      // localStorage may be unavailable (Safari private mode etc.) —
      // selection just falls back to the catalog default.
    }
    // Kick the settings store so the pinned default-slug is available
    // by the time #reconcileSelection runs.
    void agentSettings.init();
    void this.refresh();
    // Live catalog refresh (RUNTIME fs-watch → agents_list) is pending
    // on the runtime; until it lands we refresh directly on init and
    // after any nav that re-invokes init/refresh.
  }

  dispose() {
    // No live subscription to tear down.
  }

  async refresh(): Promise<void> {
    this.loading = true;
    this.lastError = null;
    try {
      const workdir = workspace.active?.folders?.[0] ?? null;
      const qs = workdir
        ? "?workdir=" + encodeURIComponent(workdir)
        : "";
      const body = await engineRequest<{ agents?: AgentCatalogEntry[] }>(
        enginePath.agents_list,
        { query: qs, timeoutMs: 5_000 },
      );
      const raw = body.agents ?? [];
      this.agents = raw
        // Drop bundled test fixtures + agents explicitly marked
        // :ICON: hidden in their .org.
        .filter(
          (a) =>
            !(a.scope === "builtin" && HIDDEN_BUILTINS.has(a.slug)) &&
            a.icon !== "hidden",
        )
        // Patch icons + taglines for known built-ins until the
        // daemon enriches.
        .map((a) => ({
          ...a,
          icon: a.icon ?? FALLBACK_ICONS[a.slug] ?? null,
          tagline: a.tagline ?? FALLBACK_TAGLINES[a.slug] ?? null,
        }));
      this.#reconcileSelection();
    } catch (e) {
      // Daemon offline (or route pending) → degrade to an empty
      // catalog without surfacing an error to the picker. Any persisted
      // selection stays put so it re-resolves once the daemon returns.
      if (
        e instanceof EngineApiError &&
        (e.code === "daemon_down" || e.code === "sidecar_down")
      ) {
        this.agents = [];
        this.lastError = null;
        return;
      }
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  /** Set the active agent and persist to the local agent_selection
   *  store. Mirrors to the shared `active` store so ws can read it
   *  without importing agents. */
  select(slug: string): void {
    this.selected = slug;
    active.agentSlug = slug;
    try {
      localStorage.setItem(SELECTION_KEY, slug);
    } catch {
      // Best-effort; ignore.
    }
  }

  /** If the persisted selection no longer resolves, fall back.
   *  Priority order:
   *    1. localStorage selection (if still in catalog)
   *    2. User-pinned default_agent_slug (Settings → Agents)
   *    3. PRIMARY_FALLBACK ("workhorse")
   *    4. First listed entry */
  #reconcileSelection(): void {
    if (this.agents.length === 0) return;
    const found =
      this.selected && this.agents.find((a) => a.slug === this.selected);
    if (found) return;
    const pinned = agentSettings.settings.default_agent_slug;
    const fallback =
      (pinned && this.agents.find((a) => a.slug === pinned)) ||
      this.agents.find((a) => a.slug === PRIMARY_FALLBACK) ||
      this.agents[0];
    this.select(fallback.slug);
  }
}

export const agents = new AgentsStore();
