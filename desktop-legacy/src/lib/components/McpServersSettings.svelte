<script lang="ts">
  /**
   * MCP server registry (wb-i38o.6 §2).
   *
   * UI-only persistence — the oql-agent doesn't read mcp-servers.json
   * today. The JSON shape is fixed so a future agent-side consumer can
   * pick the file up without rework.
   *
   * Transports:
   *   - stdio — command + args + env (most common, e.g. `npx @mcp/server-github`)
   *   - http  — URL (remote MCP server over SSE/HTTP)
   */
  import { onMount } from "svelte";
  import { Plus, Trash2, Pencil, Check, X, Server } from "@lucide/svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import {
    mcp,
    type McpServer,
    type McpTransport,
  } from "$lib/bridge/mcp_servers.svelte";
  import SettingsPanel from "./settings/SettingsPanel.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Dropdown from "./ui/Dropdown.svelte";

  let showCreate = $state(false);
  /** id being edited, or null when adding new */
  let editingId = $state<string | null>(null);

  // form state — shared between add + edit
  let fName = $state("");
  let fTransport = $state<McpTransport>("stdio");
  let fCommandOrUrl = $state("");
  let fArgsText = $state("");
  let fEnvText = $state("");
  let fEnabled = $state(true);

  let opError = $state<string | null>(null);

  onMount(() => {
    mcp.refresh();
  });

  function resetForm() {
    fName = "";
    fTransport = "stdio";
    fCommandOrUrl = "";
    fArgsText = "";
    fEnvText = "";
    fEnabled = true;
  }

  function loadInto(s: McpServer) {
    fName = s.name;
    fTransport = s.transport;
    fCommandOrUrl = s.command_or_url;
    // args + env are array/map; render as one-per-line for editing.
    fArgsText = s.args.join("\n");
    fEnvText = Object.entries(s.env)
      .map(([k, v]) => `${k}=${v}`)
      .join("\n");
    fEnabled = s.enabled;
  }

  function parseArgs(text: string): string[] {
    return text
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.length > 0);
  }

  function parseEnv(text: string): Record<string, string> {
    const out: Record<string, string> = {};
    for (const raw of text.split("\n")) {
      const line = raw.trim();
      if (!line) continue;
      const eq = line.indexOf("=");
      if (eq < 0) continue; // silently drop malformed lines — UI shows
      // an inline hint about the expected shape.
      const k = line.slice(0, eq).trim();
      const v = line.slice(eq + 1);
      if (k) out[k] = v;
    }
    return out;
  }

  function openAdd() {
    resetForm();
    editingId = null;
    showCreate = true;
  }

  function openEdit(s: McpServer) {
    loadInto(s);
    editingId = s.id;
    showCreate = true;
  }

  function cancel() {
    showCreate = false;
    editingId = null;
    resetForm();
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    opError = null;
    const payload = {
      name: fName,
      transport: fTransport,
      command_or_url: fCommandOrUrl,
      args: parseArgs(fArgsText),
      env: parseEnv(fEnvText),
      enabled: fEnabled,
    };
    try {
      if (editingId) {
        await mcp.update({ id: editingId, ...payload });
      } else {
        await mcp.create(payload);
      }
      cancel();
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function del(s: McpServer) {
    if (!(await tauriConfirm(`Delete MCP server "${s.name}"?`, { kind: "warning" }))) return;
    opError = null;
    try {
      await mcp.delete(s.id);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }
</script>

<SettingsPanel
  title="MCP servers"
  lede="Model Context Protocol servers expose external tools and resources to the agent. Configs persist to ~/.oql/desktop/mcp-servers.json."
>
  {#snippet actions()}
    <span class="chip chip-neutral">
      {mcp.servers.length} server{mcp.servers.length === 1 ? "" : "s"}
    </span>
  {/snippet}

  {#if mcp.servers.length === 0}
    <EmptyState
      icon={Server}
      title="No MCP servers yet"
      description="Add a stdio, HTTP, or WebSocket MCP endpoint to expose its tools and resources to the agent."
    />
  {:else}
    <ul class="serverlist">
      {#each mcp.servers as s (s.id)}
        <li>
          <div class="srv-row">
            <div class="srv-meta">
              <Server size={13} strokeWidth={1.8} />
              <span class="srv-name">{s.name}</span>
              <span class="transport">{s.transport}</span>
              {#if !s.enabled}
                <span class="chip chip-neutral">disabled</span>
              {/if}
            </div>
            <div class="srv-actions">
              <button
                type="button"
                class="icon-btn"
                aria-label="edit server"
                onclick={() => openEdit(s)}
              >
                <Pencil size={13} strokeWidth={1.8} />
              </button>
              <button
                type="button"
                class="icon-btn danger"
                aria-label="delete server"
                onclick={() => del(s)}
              >
                <Trash2 size={13} strokeWidth={1.8} />
              </button>
            </div>
          </div>
          <div class="srv-detail">
            <code>{s.command_or_url}</code>
            {#if s.transport === "stdio" && s.args.length > 0}
              <span class="args">
                {#each s.args as a (a)}
                  <code class="arg">{a}</code>
                {/each}
              </span>
            {/if}
          </div>
          {#if s.transport === "stdio" && Object.keys(s.env).length > 0}
            <div class="env">
              {#each Object.entries(s.env) as [k, _v] (k)}
                <code class="env-key">{k}=•••</code>
              {/each}
            </div>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  {#if showCreate}
    <form class="create-form" onsubmit={submit}>
      <h4 class="sub">{editingId ? "Edit server" : "Add server"}</h4>
      <div class="grid-form">
        <label>
          <span>Name</span>
          <input type="text" placeholder="github" bind:value={fName} required />
        </label>
        <label>
          <span>Transport</span>
          <Dropdown
            bind:value={fTransport}
            items={[
              { value: "stdio", label: "stdio", description: "Local subprocess" },
              { value: "http", label: "http", description: "HTTP / SSE endpoint" },
            ]}
          />
        </label>
        <label class="full">
          <span>
            {fTransport === "stdio" ? "Command" : "URL"}
          </span>
          <input
            type="text"
            placeholder={fTransport === "stdio" ? "npx" : "https://mcp.example.com/sse"}
            bind:value={fCommandOrUrl}
            required
          />
        </label>
        {#if fTransport === "stdio"}
          <label class="full">
            <span>Args (one per line)</span>
            <textarea
              rows="3"
              placeholder={"-y\n@modelcontextprotocol/server-github"}
              bind:value={fArgsText}
            ></textarea>
          </label>
          <label class="full">
            <span>Env vars (<code>KEY=value</code>, one per line)</span>
            <textarea
              rows="2"
              placeholder={"GITHUB_TOKEN=ghp_..."}
              bind:value={fEnvText}
            ></textarea>
          </label>
        {/if}
        <label class="checkbox">
          <input type="checkbox" bind:checked={fEnabled} />
          <span>enabled</span>
        </label>
      </div>
      <div class="form-actions">
        <button type="button" class="ghost" onclick={cancel}>cancel</button>
        <button
          type="submit"
          class="primary"
          disabled={!fName.trim() || !fCommandOrUrl.trim()}
        >
          <Check size={13} strokeWidth={1.8} />
          {editingId ? "save" : "add server"}
        </button>
      </div>
    </form>
  {:else}
    <button type="button" class="add-card" onclick={openAdd}>
      <Plus size={13} strokeWidth={2} />
      <span>Add an MCP server</span>
    </button>
  {/if}

  {#if opError}
    <div class="err-line">{opError}</div>
  {/if}
</SettingsPanel>

<style>
  .chip {
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 0.15em 0.55em;
    border-radius: 999px;
    font-weight: 600;
  }
  .chip-neutral {
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
  }
  .empty {
    padding: 1rem;
    background: var(--color-surface-soft);
    border-radius: var(--radius-md, 6px);
    color: var(--color-fg-muted);
    font-size: 0.85rem;
  }
  .empty p {
    margin: 0;
  }
  .serverlist {
    list-style: none;
    padding: 0;
    margin: 0 0 0.85rem;
  }
  .serverlist li {
    padding: 0.55rem 0.6rem;
    border-radius: var(--radius-md, 6px);
    background: var(--color-surface-soft);
    margin-bottom: 0.35rem;
  }
  .srv-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.6rem;
  }
  .srv-meta {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    color: var(--color-fg);
    flex: 1 1 auto;
    min-width: 0;
  }
  .srv-name {
    font-weight: 500;
    font-size: 0.85rem;
  }
  .transport {
    font-size: 0.7rem;
    background: var(--color-border);
    color: var(--color-fg-muted);
    padding: 0.1em 0.5em;
    border-radius: 4px;
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .srv-actions {
    display: inline-flex;
    gap: 0.25rem;
  }
  .srv-detail {
    margin-top: 0.3rem;
    color: var(--color-fg-muted);
    font-size: 0.78rem;
  }
  .srv-detail code {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    word-break: break-all;
  }
  .args {
    display: inline-flex;
    flex-wrap: wrap;
    gap: 0.3rem;
    margin-left: 0.5rem;
  }
  .args .arg {
    background: var(--color-border);
    padding: 0.05em 0.4em;
    border-radius: 3px;
    color: var(--color-fg-muted);
  }
  .env {
    margin-top: 0.25rem;
    display: inline-flex;
    flex-wrap: wrap;
    gap: 0.3rem;
  }
  .env-key {
    font-size: 0.72rem;
    background: var(--color-border);
    color: var(--color-fg-subtle);
    padding: 0.05em 0.4em;
    border-radius: 3px;
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .icon-btn {
    background: transparent;
    border: 0;
    cursor: pointer;
    color: var(--color-fg-muted);
    padding: 0.2rem;
    border-radius: var(--radius-sm, 4px);
    display: inline-flex;
    align-items: center;
  }
  .icon-btn:hover {
    color: var(--color-fg);
    background: var(--color-border);
  }
  .icon-btn.danger {
    color: #fca5a5;
  }
  .create-form {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 6px);
    padding: 0.85rem 0.9rem;
  }
  .sub {
    margin: 0 0 0.5rem;
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .grid-form {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0.5rem 0.7rem;
  }
  .grid-form label {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
    font-size: 0.72rem;
    color: var(--color-fg-muted);
  }
  .grid-form label.full {
    grid-column: 1 / -1;
  }
  .grid-form label.checkbox {
    flex-direction: row;
    align-items: center;
    gap: 0.4rem;
  }
  .grid-form input,
  .grid-form select,
  .grid-form textarea {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 6px);
    padding: 0.35rem 0.55rem;
    color: var(--color-fg);
    font-size: 0.82rem;
    font-family: inherit;
  }
  .grid-form textarea {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    resize: vertical;
  }
  .form-actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.4rem;
    margin-top: 0.6rem;
  }
  .form-actions button,
  .add-btn {
    border-radius: var(--radius-md, 6px);
    padding: 0.35rem 0.7rem;
    font-size: 0.78rem;
    font-weight: 600;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    border: 1px solid transparent;
  }
  .form-actions .ghost {
    background: transparent;
    border-color: var(--color-border);
    color: var(--color-fg);
  }
  .primary {
    background: var(--color-primary-bg);
    color: var(--color-primary-fg);
  }
  .primary:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  /* Ghost "add an MCP server" card — matches the pattern used by
   * ApiKeysSettings and PluginsSettings for list-based empty/add
   * affordances. Less commanding than a filled primary at row width. */
  .add-card {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.4rem;
    width: 100%;
    padding: 0.7rem 0.85rem;
    background: transparent;
    border: 1px dashed var(--color-border);
    border-radius: var(--radius-md, 7px);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.82rem;
    cursor: pointer;
    transition: background 0.1s, color 0.1s, border-color 0.1s;
  }
  .add-card:hover {
    background: var(--color-surface-soft);
    border-color: var(--color-border-strong);
    color: var(--color-fg);
  }
  .err-line {
    color: #fca5a5;
    font-size: 0.78rem;
    margin-top: 0.6rem;
  }
  code {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.85em;
  }
</style>
