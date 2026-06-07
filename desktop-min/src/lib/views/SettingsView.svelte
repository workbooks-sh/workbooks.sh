<script lang="ts">
  /**
   * SettingsView — sub-tabbed settings surface. A horizontal tab strip
   * over a body that swaps per tab, matching the old SettingsContainer.
   * General + Themes are implemented; the rest are placeholders shaped
   * to drop a real panel in later.
   */
  import GeneralSettings from "$lib/settings/GeneralSettings.svelte";
  import ThemesSettings from "$lib/settings/ThemesSettings.svelte";
  import SettingsPanel from "$lib/settings/SettingsPanel.svelte";

  type TabId = "general" | "agents" | "themes" | "integrations" | "skills" | "mcp" | "plugins";
  const tabs: { id: TabId; label: string }[] = [
    { id: "general", label: "General" },
    { id: "agents", label: "Agents" },
    { id: "themes", label: "Themes" },
    { id: "integrations", label: "Integrations" },
    { id: "skills", label: "Skills" },
    { id: "mcp", label: "MCPs" },
    { id: "plugins", label: "Plugins" },
  ];

  let active = $state<TabId>("general");

  const placeholders: Record<string, { title: string; lede: string }> = {
    agents: { title: "Agents", lede: "Catalog editor — name, model, and skills per agent." },
    integrations: { title: "Integrations", lede: "Toggle connected services." },
    skills: { title: "Skills", lede: "Installed skills and the marketplace." },
    mcp: { title: "MCPs", lede: "Add, remove, and test MCP servers." },
    plugins: { title: "Plugins", lede: "Install and configure OQL plugins." },
  };
</script>

<div class="settings">
  <header class="head">
    <h1>Settings</h1>
    <div class="tabs" role="tablist" aria-label="Settings sections">
      {#each tabs as t (t.id)}
        <button
          class="tab"
          class:active={active === t.id}
          role="tab"
          aria-selected={active === t.id}
          onclick={() => (active = t.id)}
        >
          {t.label}
        </button>
      {/each}
    </div>
  </header>

  <div class="body">
    {#if active === "general"}
      <GeneralSettings />
    {:else if active === "themes"}
      <ThemesSettings />
    {:else}
      {@const p = placeholders[active]}
      <SettingsPanel title={p.title} lede={p.lede}>
        <p class="soon">Coming soon — wired once the backend lands.</p>
      </SettingsPanel>
    {/if}
  </div>
</div>

<style>
  .settings {
    max-width: 720px;
    margin: 0 auto;
    padding: 1.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  h1 {
    margin: 0 0 0.6rem;
    font-size: 1.1rem;
    font-weight: 600;
  }
  .tabs {
    display: flex;
    gap: 0.25rem;
    flex-wrap: wrap;
    border-bottom: 1px solid var(--color-border);
    padding-bottom: 0.5rem;
  }
  .tab {
    height: 28px;
    padding: 0 0.65rem;
    border-radius: 7px;
    border: 1px solid transparent;
    background: transparent;
    color: var(--color-fg-muted);
    font-size: 0.8rem;
    cursor: pointer;
  }
  .tab:hover {
    color: var(--color-fg);
    background: var(--color-surface-soft);
  }
  .tab.active {
    color: var(--color-fg);
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .soon {
    margin: 0;
    font-size: 0.82rem;
    color: var(--color-fg-muted);
  }
</style>
