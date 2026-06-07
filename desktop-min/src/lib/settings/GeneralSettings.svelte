<script lang="ts">
  /**
   * GeneralSettings — identity card + account actions + engine status,
   * matching the old General panel. Reads the app-level auth store and
   * the mocked engine/sidecar commands.
   */
  import { onMount } from "svelte";
  import { auth } from "$lib/auth.svelte";
  import { commands, type EngineStatus } from "$lib/bindings";
  import SettingsPanel from "./SettingsPanel.svelte";

  let engine = $state<EngineStatus | null>(null);

  onMount(async () => {
    engine = await commands.engineStatus();
  });

  const engineLabel = $derived(
    engine?.state === "running"
      ? "Ready"
      : engine?.state === "starting"
        ? "Starting"
        : engine?.state === "crashed"
          ? "Crashed"
          : "Stopped",
  );
  const engineTone = $derived(
    engine?.state === "running" ? "ok" : engine?.state === "crashed" ? "err" : "warn",
  );
</script>

<SettingsPanel title="General" lede="Your identity, account, and the local engine status.">
  <div class="rows">
    <div class="row">
      <span class="k">Account</span>
      <span class="v">{auth.signedIn ? (auth.user?.email ?? "Signed in") : "Not signed in"}</span>
    </div>
    <div class="row">
      <span class="k">Engine</span>
      <span class="v pill {engineTone}">{engineLabel}</span>
    </div>
    <div class="row">
      <span class="k">Network ID</span>
      <span class="v">Not connected</span>
    </div>
  </div>

  <div class="actions">
    {#if auth.signedIn}
      <button class="btn ghost" disabled={auth.busy} onclick={() => void auth.signOut()}>Sign out</button>
    {:else}
      <button class="btn primary" disabled={auth.busy} onclick={() => void auth.signIn()}>Sign in</button>
    {/if}
  </div>
</SettingsPanel>

<style>
  .rows {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 0.84rem;
  }
  .k {
    color: var(--color-fg-muted);
  }
  .v {
    font-weight: 500;
  }
  .pill {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 0.7rem;
    font-weight: 600;
    border: 1px solid;
  }
  .pill.ok {
    color: var(--color-ok);
    border-color: color-mix(in srgb, var(--color-ok) 36%, transparent);
    background: color-mix(in srgb, var(--color-ok) 12%, transparent);
  }
  .pill.warn {
    color: var(--color-warn);
    border-color: color-mix(in srgb, var(--color-warn) 36%, transparent);
    background: color-mix(in srgb, var(--color-warn) 12%, transparent);
  }
  .pill.err {
    color: var(--color-err);
    border-color: color-mix(in srgb, var(--color-err) 36%, transparent);
    background: color-mix(in srgb, var(--color-err) 12%, transparent);
  }
  .actions {
    display: flex;
    gap: 0.4rem;
  }
  .btn {
    height: 30px;
    padding: 0 0.85rem;
    border-radius: 8px;
    font-size: 0.82rem;
    font-weight: 500;
    cursor: pointer;
    border: 1px solid transparent;
  }
  .btn:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover {
    color: var(--color-fg);
  }
</style>
