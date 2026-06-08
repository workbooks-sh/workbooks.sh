<script lang="ts">
  /**
   * EngineOnboarding — full-viewport splash shown on first launch
   * BEFORE the keychain step, when the launchd-managed oql-agent
   * daemon hasn't been installed yet. Triggers `engine_install` on
   * click, then polls `engine_status` until the daemon comes up.
   *
   * Pairs with KeychainOnboarding.svelte (same visual shape) so
   * the two splashes feel like one continuous onboarding.
   */
  import { Cpu } from "@lucide/svelte";
  import { engineInstall, engineStatus } from "$lib/bridge/engine.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  let busy = $state(false);
  let error = $state<string | null>(null);
  let phase = $state<"idle" | "installing" | "starting">("idle");

  async function pollUntilRunning(maxMs = 60_000) {
    const start = Date.now();
    while (Date.now() - start < maxMs) {
      const status = await engineStatus();
      if (status.state === "running") return;
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error("engine did not start within 60s");
  }

  async function install() {
    busy = true;
    error = null;
    try {
      phase = "installing";
      await engineInstall();
      phase = "starting";
      await pollUntilRunning();
      oncomplete();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      phase = "idle";
    } finally {
      busy = false;
    }
  }
</script>

<div class="screen">
  <div class="card">
    <div class="icon-row">
      <div class="icon">
        <Cpu size={28} strokeWidth={2.2} />
      </div>
    </div>

    <h1>Install the Workbooks engine</h1>
    <p class="sub">
      Workbooks runs a local engine on this Mac that keeps your
      agents warm and your data on-device. It starts automatically
      every time you log in and stays out of the way.
    </p>

    <button
      type="button"
      class="btn primary"
      onclick={install}
      disabled={busy}
      data-testid="engine-install-button"
    >
      {#if phase === "installing"}
        Installing…
      {:else if phase === "starting"}
        Starting engine…
      {:else}
        Install Engine
      {/if}
    </button>

    {#if error}
      <div class="error">{error}</div>
    {/if}
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
    max-width: 400px;
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
  .icon {
    width: 72px;
    height: 72px;
    border-radius: 18px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--color-fg);
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
    line-height: 1.55;
  }
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
  .btn:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.primary:not(:disabled):hover {
    opacity: 0.88;
  }
  .error {
    margin-top: 0.6rem;
    color: #ef4444;
    font-size: 0.78rem;
    word-break: break-word;
  }
</style>
