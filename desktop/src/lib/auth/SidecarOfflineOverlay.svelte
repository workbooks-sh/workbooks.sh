<script lang="ts">
  /**
   * Full-page overlay when the desktop renderer can't reach the
   * bundled Workhorse sidecar. User-facing copy never mentions
   * "Workhorse" or "sidecar" — just "Workbooks isn't running."
   *
   * "Try again" actually RESTARTS the sidecar process via the Tauri
   * shell (not just re-probes from JS) — if a stale BEAM crashed or
   * a port conflict killed the launch, the re-probe alone would never
   * recover. After the restart, auth.refresh() picks up the new state.
   */
  import { invoke } from "@tauri-apps/api/core";
  import { ArrowsClockwise as RefreshCw } from "phosphor-svelte";
  import EmptyState from "$lib/network/components/EmptyState.svelte";
  import { auth } from "./store.svelte";

  let retrying = $state(false);

  async function retry() {
    if (retrying) return;
    retrying = true;
    try {
      try {
        await invoke("sidecar_restart");
      } catch {
        /* swallow — refresh() reflects whatever state we end up in */
      }
      await auth.refresh();
    } finally {
      retrying = false;
    }
  }
</script>

<div class="overlay">
  <EmptyState
    title="Workbooks isn't running"
    blurb="The desktop app can't reach the local engine. This usually means a background process didn't start. Try refreshing — if it keeps happening, restart Workbooks."
    glyph="◌"
    hue={25}
  >
    {#snippet cta()}
      <button type="button" class="btn primary" onclick={retry} disabled={retrying}>
        <RefreshCw weight="fill" size={13} class={retrying ? "spinning" : ""} />
        {retrying ? "Trying again…" : "Try again"}
      </button>
    {/snippet}
  </EmptyState>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: var(--color-page);
    z-index: 1000;
    display: grid;
    place-items: center;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 9px 18px;
    border-radius: 8px;
    font-size: 0.86rem;
    font-weight: 600;
    cursor: pointer;
    border: 1px solid var(--color-fg);
    background: var(--color-fg);
    color: var(--color-page);
    transition:
      transform 180ms cubic-bezier(0.22, 1.2, 0.36, 1),
      box-shadow 200ms ease;
  }
  .btn:hover:not(:disabled) {
    transform: translateY(-1px);
    box-shadow: 0 6px 16px rgba(15, 15, 15, 0.12);
  }
  .btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }
  :global(.spinning) {
    animation: spin 900ms linear infinite;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }
</style>
