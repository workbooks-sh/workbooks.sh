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
  import GeneralSettings from "$lib/components/settings/GeneralSettings.svelte";
  import AgentsSettings from "$lib/components/AgentsSettings.svelte";
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

  type Tab = { id: TabId; label: string };
  const tabs: Tab[] = [
    { id: "general", label: "General" },
    { id: "agents", label: "Agents" },
    { id: "themes", label: "Themes" },
    { id: "integrations", label: "Integrations" },
    { id: "skills", label: "Skills" },
    { id: "mcp", label: "MCPs" },
    { id: "plugins", label: "Plugins" },
  ];

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
      <AgentsSettings />
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
    font: inherit;
    font-size: 0.85rem;
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: color 0.1s, border-color 0.1s;
    margin-bottom: -1px;
  }
  .tab:hover { color: var(--color-fg); }
  .tab.active {
    color: var(--color-fg);
    border-bottom-color: var(--color-fg);
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
