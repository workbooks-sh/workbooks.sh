<script lang="ts">
  /**
   * WorkspaceOnboarding — first-run screen shown only when zero Workspaces
   * exist. The default "Personal" workspace is auto-created by the shell the
   * moment the nexus (local sidecar) is ready (wb-2s09.9), so this screen's
   * real job is the BEFORE-that case: give the user a way to connect/boot
   * their engine (wb-2s09.10). An offline escape stays available so the
   * desktop never hard-gates on the engine (desktop is offline-first).
   */
  import { Check, Plugs, ArrowClockwise } from "phosphor-svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  let busy = $state(false);
  let error = $state<string | null>(null);

  const state = $derived(sidecar.status.state);
  const connecting = $derived(state === "starting" || state === "restarting");

  async function connect() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await sidecar.up(); // boot the local runtime; parent auto-creates on ready
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  // Offline escape — create the default workspace locally without the engine.
  async function continueOffline() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await workspaces.create("Personal", "✨");
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
    <div class="badge" class:warn={state === "unhealthy" || state === "crashed"}>
      <Plugs weight="fill" size={28} />
    </div>

    <h1>Connect your engine</h1>
    <p class="sub">
      Workbooks runs against a nexus — your engine. Once it's connected we'll
      set up your <strong>Personal</strong> workspace automatically.
    </p>

    <div class="status" data-state={state}>
      <span class="dot"></span>
      {#if connecting}Connecting to the engine…
      {:else if state === "unhealthy"}Engine reachable but unhealthy
      {:else if state === "crashed"}Engine stopped unexpectedly
      {:else}No engine connected{/if}
    </div>

    <div class="actions">
      <button type="button" class="btn primary" onclick={connect} disabled={busy || connecting}>
        {#if connecting || busy}
          <ArrowClockwise weight="bold" size={14} class="spin" /> Connecting…
        {:else}
          <Plugs weight="bold" size={14} /> Connect engine
        {/if}
      </button>
      <button type="button" class="btn ghost" onclick={continueOffline} disabled={busy}>
        <Check weight="bold" size={13} /> Continue offline
      </button>
    </div>

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
    max-width: 390px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 2rem 2rem 1.75rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
  }
  .badge {
    display: grid;
    place-items: center;
    width: 60px;
    height: 60px;
    border-radius: 16px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    margin-bottom: 1.1rem;
  }
  .badge.warn { color: var(--color-warn); }
  h1 {
    margin: 0 0 0.4rem;
    font-size: 1.1rem;
    font-weight: 600;
    letter-spacing: -0.015em;
  }
  .sub {
    margin: 0 0 1.2rem;
    color: var(--color-fg-muted);
    font-size: 0.84rem;
    line-height: 1.5;
  }
  .sub strong { color: var(--color-fg); font-weight: 600; }
  .status {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-family: var(--font-mono);
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    margin-bottom: 1.2rem;
  }
  .status .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--color-fg-subtle);
  }
  .status[data-state="unhealthy"] .dot,
  .status[data-state="crashed"] .dot { background: var(--color-warn); }
  .status[data-state="starting"] .dot,
  .status[data-state="restarting"] .dot { background: var(--color-ok); }
  .actions {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    width: 100%;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.4rem;
    height: 38px;
    border-radius: 10px;
    font-size: 0.88rem;
    font-weight: 500;
    font-family: var(--font-mono);
    cursor: pointer;
    border: 1px solid transparent;
    transition: filter 0.15s, transform 0.2s, background 0.15s;
  }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.primary:not(:disabled):hover { filter: brightness(1.08); transform: translateY(-1px); }
  .btn.ghost {
    background: transparent;
    border-color: var(--color-border);
    color: var(--color-fg-muted);
  }
  .btn.ghost:not(:disabled):hover { color: var(--color-fg); border-color: var(--color-border-strong); }
  .btn :global(.spin) { animation: ob-spin 0.9s linear infinite; }
  @keyframes ob-spin { to { transform: rotate(360deg); } }
  .error {
    margin-top: 0.6rem;
    color: var(--color-err);
    font-size: 0.78rem;
    word-break: break-word;
  }
</style>
