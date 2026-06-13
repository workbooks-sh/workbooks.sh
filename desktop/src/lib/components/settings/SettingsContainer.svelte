<script lang="ts">
  /**
   * SettingsContainer — sub-tabbed Settings surface.
   *
   * Top: horizontal tab strip. Body: the active tab's panel.
   * All settings panels were previously rendered as a single long
   * scroll inside +page.svelte; this lifts them into a clean tabbed
   * structure that scales as new categories land.
   *
   * Honors `chrome.settingsTab` so other surfaces (e.g. the chat
   * header's "Edit agent" menu) can deep-link into a specific tab.
   * The container consumes + clears the request after applying it.
   */
  import { chrome } from "$lib/ui/chrome.svelte";
  import { features } from "$lib/bridge/features";
  import GeneralSettings from "$lib/components/settings/GeneralSettings.svelte";
  // AgentsSettings is lazy-loaded (wb-aakl.2): its static import pulled
  // chat/ (ModelPicker, AgentEditor) + agent stores into the main chunk.
  // The agents tab only appears under WB_FF_AGENTS, so a flags-off build
  // never reaches the dynamic import and the whole chain is excluded.
  import McpServersSettings from "$lib/components/McpServersSettings.svelte";
  import PluginsSettings from "$lib/components/PluginsSettings.svelte";
  import IntegrationsSettings from "$lib/components/IntegrationsSettings.svelte";
  import SkillsSettings from "$lib/components/SkillsSettings.svelte";
  import ThemesSettings from "$lib/components/ThemesSettings.svelte";

  // Account folds into General — sign-in lives next to sidecar
  // status; no separate tab. Packages was a one-card view that
  // duplicated rail content; dropped. MCP Servers shortened to
  // "MCPs" — the tab strip was getting too wide.
  type TabId =
    | "general"
    | "agents"
    | "themes"
    | "integrations"
    | "skills"
    | "mcp"
    | "plugins";

  // Flag-gated tabs (wb-aakl.1): Agents needs WB_FF_AGENTS; the
  // Integrations/Skills/MCPs/Plugins cluster needs WB_FF_INTEGRATIONS.
  // The shipped browser shows only General + Themes (+ Connection later,
  // wb-aakl.6). Deep bundle-exclusion of these panels is wb-aakl.4.
  type Tab = { id: TabId; label: string; on: boolean };
  const tabs: Tab[] = (
    [
      { id: "general", label: "General", on: true },
      { id: "agents", label: "Agents", on: features.agents },
      { id: "themes", label: "Themes", on: true },
      { id: "integrations", label: "Integrations", on: features.integrations },
      { id: "skills", label: "Skills", on: features.integrations },
      { id: "mcp", label: "MCPs", on: features.integrations },
      { id: "plugins", label: "Plugins", on: features.integrations },
    ] satisfies Tab[]
  ).filter((t) => t.on);

  let active = $state<TabId>("general");

  // Honor deep-link nav requests from other components. Consume + clear.
  // Legacy deep-links to "account" or "packages" (now folded/removed)
  // fall through to General — the natural landing place for both.
  $effect(() => {
    const t = chrome.settingsTab;
    if (!t) return;
    if (tabs.find((x) => x.id === t)) {
      active = t as TabId;
    } else if (t === "account" || t === "packages") {
      active = "general";
    }
    chrome.settingsTab = null;
  });
</script>

<div class="settings">
  <header class="head">
    <h1>Settings</h1>
    <nav class="tabs" role="tablist" aria-label="Settings sections">
      {#each tabs as t (t.id)}
        <button
          type="button"
          class="tab"
          class:active={active === t.id}
          role="tab"
          aria-selected={active === t.id}
          onclick={() => (active = t.id)}
        >
          {t.label}
        </button>
      {/each}
    </nav>
  </header>

  <div class="body">
    {#if active === "general"}
      <GeneralSettings />
    {:else if active === "agents"}
      {#await import("$lib/components/AgentsSettings.svelte") then M}
        <M.default />
      {/await}
    {:else if active === "themes"}
      <ThemesSettings />
    {:else if active === "integrations"}
      <IntegrationsSettings />
    {:else if active === "skills"}
      <SkillsSettings />
    {:else if active === "mcp"}
      <McpServersSettings />
    {:else if active === "plugins"}
      <PluginsSettings />
    {/if}
  </div>
</div>

<style>
  .settings {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .head {
    flex-shrink: 0;
    padding: 1rem 1.5rem 0;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-page);
  }
  h1 {
    margin: 0 0 0.6rem;
    font-size: 1.1rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .tabs {
    display: flex;
    gap: 0;
    align-items: flex-end;
    overflow-x: auto;
    scrollbar-width: thin;
  }
  .tab {
    background: transparent;
    border: 0;
    border-bottom: 2px solid transparent;
    padding: 0.5rem 0.85rem;
    font-family: var(--font-mono);
    font-size: 12px;
    letter-spacing: 0.02em;
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: color 0.15s, border-color 0.15s;
    margin-bottom: -1px;
  }
  .tab:hover { color: var(--color-fg); }
  .tab.active {
    color: var(--color-fg);
    border-bottom-color: var(--color-brand);
    font-weight: 500;
  }
  .body {
    flex: 1 1 auto;
    min-height: 0;
    overflow: auto;
    padding: 1.25rem 1.5rem 2rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
</style>
