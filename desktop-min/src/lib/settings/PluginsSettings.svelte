<script lang="ts">
  /**
   * PluginsSettings — OQL plugin registry. Toggle to enable, remove to
   * uninstall, and install by source string. Registry-only for now;
   * agent-side loading lands with the backend.
   */
  import { onMount } from "svelte";
  import { Plus, Trash2, Puzzle } from "@lucide/svelte";
  import { commands, type Plugin } from "$lib/bindings";
  import SettingsPanel from "./SettingsPanel.svelte";

  let plugins = $state<Plugin[]>([]);
  let adding = $state(false);
  let fSource = $state("");

  onMount(async () => {
    plugins = await commands.pluginsList();
  });

  async function toggle(p: Plugin) {
    await commands.pluginsSetEnabled({ id: p.id, enabled: !p.enabled });
    plugins = plugins.map((x) => (x.id === p.id ? { ...x, enabled: !x.enabled } : x));
  }

  async function remove(p: Plugin) {
    await commands.pluginsRemove(p.id);
    plugins = plugins.filter((x) => x.id !== p.id);
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    if (!fSource.trim()) return;
    const created = await commands.pluginsInstall({ source: fSource.trim() });
    plugins = [...plugins, created];
    fSource = "";
    adding = false;
  }
</script>

<SettingsPanel title="Plugins" lede="OQL SaaS adapters as first-class plugins. Install by source, toggle to enable.">
  {#snippet actions()}
    <button class="add" onclick={() => (adding = !adding)}>
      <Plus size={12} strokeWidth={2} /> Install
    </button>
  {/snippet}

  {#if adding}
    <form class="form" onsubmit={submit}>
      <input bind:value={fSource} placeholder="Source (e.g. oql://stripe or a git URL)" />
      <button class="primary" type="submit">Install</button>
    </form>
  {/if}

  {#if plugins.length === 0}
    <p class="empty"><Puzzle size={14} strokeWidth={1.8} /> No plugins installed.</p>
  {:else}
    <ul class="list">
      {#each plugins as p (p.id)}
        <li class="row">
          <span class="ico"><Puzzle size={14} strokeWidth={1.8} /></span>
          <span class="body"><span class="title">{p.name}</span></span>
          <label class="switch" title={p.enabled ? "Enabled" : "Disabled"}>
            <input type="checkbox" checked={p.enabled} onchange={() => toggle(p)} />
            <span class="track"></span>
          </label>
          <button class="del" title="Uninstall" aria-label="Uninstall" onclick={() => remove(p)}>
            <Trash2 size={13} strokeWidth={1.8} />
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</SettingsPanel>

<style>
  .add,
  .primary {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 28px;
    padding: 0 0.7rem;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.76rem;
    font-weight: 500;
    cursor: pointer;
  }
  .primary {
    border-color: transparent;
    background: var(--color-fg);
    color: var(--color-page);
  }
  .form {
    display: flex;
    gap: 0.4rem;
  }
  .form input {
    flex: 1;
    min-width: 0;
    height: 30px;
    padding: 0 0.55rem;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.8rem;
  }
  .form input:focus {
    outline: none;
    border-color: var(--color-border-strong);
  }
  .empty {
    margin: 0;
    display: flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.82rem;
    color: var(--color-fg-muted);
  }
  .list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.45rem 0.5rem;
    border: 1px solid transparent;
    border-radius: 8px;
  }
  .row:hover {
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .ico {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    flex-shrink: 0;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
  }
  .body {
    flex: 1;
    min-width: 0;
  }
  .title {
    font-size: 0.84rem;
    font-weight: 600;
  }
  .switch {
    flex-shrink: 0;
    position: relative;
    width: 30px;
    height: 18px;
    cursor: pointer;
  }
  .switch input {
    position: absolute;
    opacity: 0;
    inset: 0;
    margin: 0;
    cursor: pointer;
  }
  .track {
    position: absolute;
    inset: 0;
    border-radius: 999px;
    background: var(--color-border-strong);
    transition: background 0.15s ease;
  }
  .track::after {
    content: "";
    position: absolute;
    top: 2px;
    left: 2px;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: var(--color-surface);
    transition: transform 0.15s ease;
  }
  .switch input:checked + .track {
    background: var(--color-ok);
  }
  .switch input:checked + .track::after {
    transform: translateX(12px);
  }
  .del {
    flex-shrink: 0;
    padding: 0.3rem;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
  }
  .del:hover {
    background: var(--color-border);
    color: var(--color-err);
  }
</style>
