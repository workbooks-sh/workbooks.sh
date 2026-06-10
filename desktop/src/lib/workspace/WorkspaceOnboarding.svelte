<script lang="ts">
  /**
   * WorkspaceOnboarding — first-run screen shown only when zero
   * Workspaces exist. One step: name + emoji icon. No folder pick, no
   * key pasting — just the canonical "where am I working" decision.
   *
   * Packages (projects/folders) get created later from the rail's "+"
   * button; API keys live in Settings.
   *
   * Per docs/canonical-model.md.
   */
  import { Check } from "phosphor-svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import IconPickerMenu from "./IconPickerMenu.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  let name = $state("");
  let icon = $state("✨");
  let busy = $state(false);
  let error = $state<string | null>(null);

  async function submit() {
    const n = name.trim();
    if (!n) return;
    busy = true;
    error = null;
    try {
      await workspaces.create(n, icon);
      oncomplete();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }
</script>

<div class="screen">
  <div class="card">
    <div class="icon-row">
      <IconPickerMenu bind:value={icon} name={name || "Workspace"} size={72} />
    </div>

    <h1>Name your workspace</h1>
    <p class="sub">
      A workspace is an area of work — day job, startup, personal. You
      can add more later from the rail.
    </p>

    <form onsubmit={(e) => { e.preventDefault(); submit(); }}>
      <input
        type="text"
        placeholder="Personal"
        bind:value={name}
        autofocus
        disabled={busy}
      />
      <button
        type="submit"
        class="btn primary"
        disabled={busy || !name.trim()}
      >
        <Check weight="bold" size={14} /> Create workspace
      </button>
    </form>

    {#if error}<div class="error">{error}</div>{/if}
  </div>
</div>

<style>
  .screen {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
    background: var(--color-page);
    -webkit-app-region: drag;
    overflow: auto;
  }
  .card {
    -webkit-app-region: no-drag;
    width: 100%;
    max-width: 380px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 2rem 2rem 1.75rem;
    display: flex;
    flex-direction: column;
    text-align: center;
  }
  .icon-row {
    display: flex;
    justify-content: center;
    margin-bottom: 1.25rem;
  }
  h1 {
    margin: 0 0 0.4rem;
    font-size: 1.1rem;
    font-weight: 600;
    letter-spacing: -0.015em;
  }
  .sub {
    margin: 0 0 1.4rem;
    color: var(--color-fg-muted);
    font-size: 0.84rem;
    line-height: 1.5;
  }
  form {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  input {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 0.55rem 0.75rem;
    font-size: 0.92rem;
    font-family: inherit;
    color: var(--color-fg);
    outline: 0;
    text-align: center;
  }
  input:focus { border-color: var(--color-border-strong); }
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.4rem;
    height: 38px;
    border-radius: 9px;
    font-size: 0.88rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    border: 0;
    transition: opacity 0.12s;
  }
  .btn:disabled { opacity: 0.45; cursor: default; }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.primary:not(:disabled):hover { opacity: 0.88; }
  .error {
    margin-top: 0.6rem;
    color: #ef4444;
    font-size: 0.78rem;
    word-break: break-word;
  }
</style>
