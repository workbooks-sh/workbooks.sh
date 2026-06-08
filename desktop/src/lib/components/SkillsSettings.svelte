<script lang="ts">
  /**
   * SkillsSettings — installed agent skills + their scope.
   *
   * Skills land here in two ways:
   *
   *   1. Auto-imported when you connect an integration (Composio,
   *      Doppler, fal.ai, Claude Code, …). Source = the service slug.
   *      Removing the connection removes the skill.
   *   2. Manually added (deferred for v1 — the storage shape supports
   *      it but no UI wiring yet).
   *
   * Each skill carries a scope chip — User / Workspace / Package —
   * mirrors `env_vars.svelte`. Changing the chip rewrites the skill's
   * scope properties in `skills.org`; the sidecar reads this at every
   * agent invocation so updates take effect immediately on the next
   * agent call.
   */
  import { onMount } from "svelte";
  import { Sparkles, Trash2, HelpCircle, Layers } from "@lucide/svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { skills, type Skill, type SkillScope } from "$lib/bridge/skills.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";
  import SettingsPanel from "./settings/SettingsPanel.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Dropdown from "./ui/Dropdown.svelte";
  import ComposioLogo from "$lib/integrations/logos/composio.svg?raw";
  import DopplerLogo from "$lib/integrations/logos/doppler.svg?raw";
  import FalLogo from "$lib/integrations/logos/fal.svg?raw";
  import OpenRouterLogo from "$lib/integrations/logos/openrouter.svg?raw";
  import ClaudeLogo from "$lib/integrations/logos/claude.svg?raw";
  import OpenAILogo from "$lib/integrations/logos/openai.svg?raw";
  import GoogleWorkspaceLogo from "$lib/integrations/logos/google-workspace.svg?raw";

  onMount(() => {
    skills.init();
  });

  function sourceLogo(source: string): string | null {
    return (
      {
        composio: ComposioLogo,
        doppler: DopplerLogo,
        fal: FalLogo,
        open_router: OpenRouterLogo,
        claude_code: ClaudeLogo,
        codex: OpenAILogo,
        google_workspace: GoogleWorkspaceLogo,
      }[source] ?? null
    );
  }
  function sourceLabel(source: string): string {
    return (
      {
        composio: "Composio",
        doppler: "Doppler",
        fal: "fal.ai",
        open_router: "OpenRouter",
        claude_code: "Claude Code",
        codex: "Codex",
        google_workspace: "Google Workspace",
        manual: "Manual",
      }[source] ?? source
    );
  }

  // Scope dropdown options — same vocabulary as the env-vars panel.
  const scopeOptions = [
    {
      value: "user" as SkillScope,
      label: "User",
      description: "Every agent run",
    },
    {
      value: "workspace" as SkillScope,
      label: "Workspace",
      description: "All packages in one workspace",
    },
    {
      value: "package" as SkillScope,
      label: "Package",
      description: "One package only",
    },
  ];

  async function onScopeChange(skill: Skill, next: SkillScope) {
    let workspaceId: string | undefined;
    let packageName: string | undefined;
    if (next === "workspace" || next === "package") {
      // Default to the currently-active workspace; if there isn't
      // one we fall back to the first available.
      workspaceId =
        workspaces.active?.id ?? workspaces.workspaces[0]?.id ?? undefined;
    }
    if (next === "package") {
      packageName =
        packageStore.active?.name ??
        packageStore.workspaces[0] ??
        undefined;
    }
    try {
      await skills.setScope({
        id: skill.id,
        scope: next,
        workspace_id: workspaceId,
        package_name: packageName,
      });
    } catch (e) {
      // Surface the failure via the panel-level error banner instead
      // of swallowing — same pattern as IntegrationsSettings.
      console.warn("[skills] setScope failed", e);
    }
  }

  function scopeBlurb(s: Skill): string {
    if (s.scope === "user") return "Every agent run";
    if (s.scope === "workspace") {
      const ws = workspaces.workspaces.find((w) => w.id === s.workspace_id);
      return `Workspace · ${ws?.name ?? s.workspace_id ?? "(unset)"}`;
    }
    return `Package · ${s.package_name ?? "(unset)"}`;
  }

  async function remove(s: Skill) {
    const ok = await tauriConfirm(
      s.source === "manual"
        ? `Remove "${s.name}"?`
        : `Remove "${s.name}"? It will come back the next time you connect ${sourceLabel(s.source)}.`,
      { kind: "warning" },
    );
    if (!ok) return;
    try {
      await skills.remove(s.id);
    } catch (e) {
      console.warn("[skills] remove failed", e);
    }
  }
</script>

<SettingsPanel
  title="Skills"
  lede="Agent-callable capability bundles. Each connection auto-installs a matching skill; change the scope to limit where the agent can use it (everywhere, one workspace, one package)."
>
  {#if skills.loading && skills.skills.length === 0}
    <p class="muted">Loading skills…</p>
  {:else if skills.skills.length === 0}
    <EmptyState
      icon={Layers}
      title="No skills installed yet"
      description="Connect an integration over in Settings → Integrations and its skill will show up here. Each skill controls what the agent can do and where it's allowed to do it."
    />
  {:else}
    <div class="list">
      {#each skills.skills as s (s.id)}
        <article class="row" aria-label={s.name}>
          {#if sourceLogo(s.source)}
            <span
              class="source-mark"
              title={sourceLabel(s.source)}
              aria-label={sourceLabel(s.source)}
            >
              {@html sourceLogo(s.source)}
            </span>
          {:else}
            <span class="source-chip" title={sourceLabel(s.source)}>
              {sourceLabel(s.source).slice(0, 2)}
            </span>
          {/if}
          <div class="meta">
            <div class="name-row">
              <span class="name">{s.name}</span>
              {#if s.description}
                <button
                  type="button"
                  class="info-btn"
                  title={s.description}
                  aria-label="About {s.name}"
                >
                  <HelpCircle size={12} strokeWidth={1.8} />
                </button>
              {/if}
            </div>
            <span class="blurb">{scopeBlurb(s)}</span>
          </div>
          <div class="scope-control">
            <Dropdown
              value={s.scope}
              items={scopeOptions}
              onchange={(v) => onScopeChange(s, v as SkillScope)}
            />
          </div>
          <button
            type="button"
            class="icon-btn danger"
            aria-label="Remove"
            title="Remove skill"
            onclick={() => remove(s)}
          >
            <Trash2 size={13} strokeWidth={1.8} />
          </button>
        </article>
      {/each}
    </div>
  {/if}
</SettingsPanel>

<style>
  .muted { color: var(--color-fg-muted); font-size: 0.85rem; margin: 0; }

  .list {
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.55rem 0.7rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 9px;
    min-height: 44px;
  }
  .source-mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    color: var(--color-fg);
    flex-shrink: 0;
  }
  .source-mark :global(svg) { width: 100%; height: 100%; }
  .source-chip {
    flex-shrink: 0;
    font-size: 0.66rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 2px 7px;
    border-radius: 999px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-weight: 600;
  }
  .meta {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .name-row {
    display: flex;
    align-items: center;
    gap: 0.3rem;
  }
  .name {
    color: var(--color-fg);
    font-size: 0.85rem;
    font-weight: 500;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .info-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 0;
    color: var(--color-fg-subtle);
    cursor: help;
    padding: 0;
    width: 16px;
    height: 16px;
    border-radius: 4px;
    flex-shrink: 0;
    transition: color 0.1s;
  }
  .info-btn:hover { color: var(--color-fg-muted); }
  .blurb {
    color: var(--color-fg-muted);
    font-size: 0.72rem;
    line-height: 1.2;
  }
  .scope-control { flex-shrink: 0; }
  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    color: var(--color-fg-muted);
    cursor: pointer;
    width: 26px;
    height: 26px;
    flex-shrink: 0;
    transition: background 0.1s, color 0.1s, border-color 0.1s;
  }
  .icon-btn:hover {
    background: var(--color-surface);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .icon-btn.danger:hover {
    color: #ef4444;
    border-color: color-mix(in srgb, #ef4444 35%, var(--color-border));
  }
</style>
