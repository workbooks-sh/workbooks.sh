<script lang="ts">
  /**
   * Plugin registry (wb-i38o.6 §3).
   *
   * Registry-only UI for v1 — agent-side plugin loading is OUT OF
   * SCOPE for this ticket. The JSON shape is fixed at
   * `~/.oql/desktop/plugins.json` so a future runtime iteration can
   * read it without schema churn.
   */
  import { onMount } from "svelte";
  import { Plus, Trash2, Check, Puzzle } from "@lucide/svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import {
    plugins,
    type Plugin,
  } from "$lib/bridge/plugins.svelte";
  import SettingsPanel from "./settings/SettingsPanel.svelte";
  import EmptyState from "./ui/EmptyState.svelte";

  let showCreate = $state(false);
  let fName = $state("");
  let fSource = $state("");
  let fVersion = $state("");
  let fEnabled = $state(true);
  let opError = $state<string | null>(null);

  onMount(() => {
    plugins.refresh();
  });

  function resetForm() {
    fName = "";
    fSource = "";
    fVersion = "";
    fEnabled = true;
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    opError = null;
    try {
      await plugins.install({
        name: fName,
        source: fSource,
        version: fVersion,
        enabled: fEnabled,
      });
      resetForm();
      showCreate = false;
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function toggle(p: Plugin) {
    opError = null;
    try {
      await plugins.setEnabled(p.id, !p.enabled);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function remove(p: Plugin) {
    if (!(await tauriConfirm(`Remove plugin "${p.name}"?`, { kind: "warning" }))) return;
    opError = null;
    try {
      await plugins.remove(p.id);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  function fmtDate(ms: number) {
    return new Date(ms).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  }
</script>

<SettingsPanel
  title="Plugins"
  lede="Extensions that add tools or behaviour to the agent. v1 is registry-only — entries persist to ~/.oql/desktop/plugins.json; runtime loading is a follow-up."
>
  {#snippet actions()}
    <span class="chip chip-neutral">
      {plugins.plugins.length} plugin{plugins.plugins.length === 1 ? "" : "s"}
    </span>
  {/snippet}

  {#if plugins.plugins.length === 0}
    <EmptyState
      icon={Puzzle}
      title="No plugins installed"
      description="Add a plugin by URL, absolute path, or registry name. v1 catalogs the entry; runtime loading is on the way."
    />
  {:else}
    <ul class="plugin-list">
      {#each plugins.plugins as p (p.id)}
        <li>
          <div class="p-row">
            <div class="p-meta">
              <Puzzle size={13} strokeWidth={1.8} />
              <span class="p-name">{p.name}</span>
              {#if p.version}
                <span class="version">v{p.version}</span>
              {/if}
              {#if !p.enabled}
                <span class="chip chip-neutral">disabled</span>
              {/if}
            </div>
            <div class="p-actions">
              <span class="date">{fmtDate(p.installed_at)}</span>
              <label class="switch" title={p.enabled ? "disable" : "enable"}>
                <input
                  type="checkbox"
                  checked={p.enabled}
                  onchange={() => toggle(p)}
                />
                <span class="slider"></span>
              </label>
              <button
                type="button"
                class="icon-btn danger"
                aria-label="remove plugin"
                onclick={() => remove(p)}
              >
                <Trash2 size={13} strokeWidth={1.8} />
              </button>
            </div>
          </div>
          <div class="p-source">
            <code>{p.source}</code>
          </div>
        </li>
      {/each}
    </ul>
  {/if}

  {#if showCreate}
    <form class="create-form" onsubmit={submit}>
      <h4 class="sub">Install plugin</h4>
      <div class="grid-form">
        <label>
          <span>Name</span>
          <input type="text" placeholder="wraith" bind:value={fName} required />
        </label>
        <label>
          <span>Version (optional)</span>
          <input type="text" placeholder="0.1.0" bind:value={fVersion} />
        </label>
        <label class="full">
          <span>Source (URL, path, or registry name)</span>
          <input
            type="text"
            placeholder="https://github.com/workbooks-sh/wraith"
            bind:value={fSource}
            required
          />
        </label>
        <label class="checkbox">
          <input type="checkbox" bind:checked={fEnabled} />
          <span>enabled</span>
        </label>
      </div>
      <div class="form-actions">
        <button
          type="button"
          class="ghost"
          onclick={() => {
            showCreate = false;
            resetForm();
          }}
        >
          cancel
        </button>
        <button
          type="submit"
          class="primary"
          disabled={!fName.trim() || !fSource.trim()}
        >
          <Check size={13} strokeWidth={1.8} /> install
        </button>
      </div>
    </form>
  {:else}
    <button
      type="button"
      class="add-card"
      onclick={() => (showCreate = true)}
    >
      <Plus size={13} strokeWidth={2} />
      <span>Install a plugin</span>
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
  .empty p {
    margin: 0;
  }
  .plugin-list {
    list-style: none;
    padding: 0;
    margin: 0 0 0.85rem;
  }
  .plugin-list li {
    padding: 0.55rem 0.6rem;
    border-radius: var(--radius-md, 6px);
    background: var(--color-surface-soft);
    margin-bottom: 0.35rem;
  }
  .p-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.6rem;
  }
  .p-meta {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    color: var(--color-fg);
    flex: 1 1 auto;
    min-width: 0;
  }
  .p-name {
    font-weight: 500;
    font-size: 0.85rem;
  }
  .version {
    font-size: 0.7rem;
    background: var(--color-border);
    color: var(--color-fg-muted);
    padding: 0.1em 0.5em;
    border-radius: 4px;
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .p-actions {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
  }
  .date {
    color: var(--color-fg-subtle);
    font-size: 0.72rem;
  }
  .p-source {
    margin-top: 0.3rem;
    color: var(--color-fg-muted);
    font-size: 0.78rem;
  }
  .p-source code {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    word-break: break-all;
  }
  .switch {
    position: relative;
    display: inline-block;
    width: 26px;
    height: 14px;
  }
  .switch input {
    opacity: 0;
    width: 0;
    height: 0;
  }
  .slider {
    position: absolute;
    inset: 0;
    background: var(--color-border);
    border-radius: 999px;
    transition: background 0.15s;
    cursor: pointer;
  }
  .slider::before {
    content: "";
    position: absolute;
    width: 10px;
    height: 10px;
    left: 2px;
    top: 2px;
    border-radius: 999px;
    background: var(--color-fg-muted);
    transition: transform 0.15s, background 0.15s;
  }
  .switch input:checked + .slider {
    background: #064e3b;
  }
  .switch input:checked + .slider::before {
    transform: translateX(12px);
    background: #d1fae5;
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
  .grid-form input {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 6px);
    padding: 0.35rem 0.55rem;
    color: var(--color-fg);
    font-size: 0.82rem;
    font-family: inherit;
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
  /* Ghost "install a plugin" card — matches the ApiKeysSettings
   * pattern. Same dashed-border affordance as the empty-state
   * surface; calmer than a filled primary at full row width. */
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
