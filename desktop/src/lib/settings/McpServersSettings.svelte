<script lang="ts">
  /**
   * McpServersSettings — registry of MCP servers. Each row toggles
   * enabled / removes; the inline form adds a stdio command. UI-only
   * persistence for now — the runtime consumer lands with the backend.
   */
  import { onMount } from "svelte";
  import { Plus, Trash2, Server } from "@lucide/svelte";
  import { commands, type McpServer } from "$lib/bindings";
  import SettingsPanel from "./SettingsPanel.svelte";

  let servers = $state<McpServer[]>([]);
  let adding = $state(false);
  let fName = $state("");
  let fCommand = $state("");

  onMount(async () => {
    servers = await commands.mcpList();
  });

  async function toggle(s: McpServer) {
    const updated = await commands.mcpUpdate({ id: s.id, enabled: !s.enabled });
    servers = servers.map((x) => (x.id === s.id ? updated : x));
  }

  async function remove(s: McpServer) {
    await commands.mcpDelete(s.id);
    servers = servers.filter((x) => x.id !== s.id);
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    if (!fName.trim() || !fCommand.trim()) return;
    const created = await commands.mcpCreate({ name: fName.trim(), command: fCommand.trim() });
    servers = [...servers, created];
    fName = "";
    fCommand = "";
    adding = false;
  }
</script>

<SettingsPanel title="MCPs" lede="Model Context Protocol servers the agent can reach. Toggle to enable; add a stdio command below.">
  {#snippet actions()}
    <button class="add" onclick={() => (adding = !adding)}>
      <Plus size={12} strokeWidth={2} /> Add server
    </button>
  {/snippet}

  {#if adding}
    <form class="form" onsubmit={submit}>
      <input bind:value={fName} placeholder="Name (e.g. GitHub)" />
      <input bind:value={fCommand} placeholder="Command (e.g. npx @mcp/server-github)" />
      <button class="primary" type="submit">Save</button>
    </form>
  {/if}

  {#if servers.length === 0}
    <p class="empty"><Server size={14} strokeWidth={1.8} /> No MCP servers configured.</p>
  {:else}
    <ul class="list">
      {#each servers as s (s.id)}
        <li class="row">
          <span class="ico"><Server size={14} strokeWidth={1.8} /></span>
          <span class="body">
            <span class="title">{s.name}</span>
            <span class="meta"><code>{s.command}</code></span>
          </span>
          <label class="switch" title={s.enabled ? "Enabled" : "Disabled"}>
            <input type="checkbox" checked={s.enabled} onchange={() => toggle(s)} />
            <span class="track"></span>
          </label>
          <button class="del" title="Remove" aria-label="Remove" onclick={() => remove(s)}>
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
    flex-wrap: wrap;
  }
  .form input {
    flex: 1;
    min-width: 120px;
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
    display: flex;
    flex-direction: column;
    gap: 0.05rem;
  }
  .title {
    font-size: 0.84rem;
    font-weight: 600;
  }
  .meta {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .meta code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
