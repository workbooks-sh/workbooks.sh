<script lang="ts">
  /**
   * KeychainOnboarding — full-viewport splash shown on the very
   * first launch, BEFORE WorkspaceOnboarding. Non-dismissable;
   * the user has to click the button to proceed. One job: trigger
   * the OS Keychain prompt with context, so the prompt isn't a
   * surprise.
   *
   * Per the explicit user direction on 2026-05-25: minimal words,
   * minimal components, full splash (not a modal), no escape hatch.
   *
   * Mirrors the visual shape of WorkspaceOnboarding.svelte so the
   * two splash screens feel like one continuous onboarding even
   * though they're rendered separately.
   */
  import { Lock } from "@lucide/svelte";
  import { setupInitializeKeychain } from "$lib/bridge/setup.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  let busy = $state(false);
  let error = $state<string | null>(null);

  async function setup() {
    busy = true;
    error = null;
    try {
      await setupInitializeKeychain();
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
      <div class="icon">
        <Lock size={28} strokeWidth={2.2} />
      </div>
    </div>

    <h1>Set up secure storage</h1>
    <p class="sub">
      Workbooks keeps your API keys and tokens on this device,
      encrypted with a key stored in your macOS Keychain. macOS will
      ask once for permission — choose <strong>Always Allow</strong>
      to skip future prompts.
    </p>

    <button
      type="button"
      class="btn primary"
      onclick={setup}
      disabled={busy}
      data-testid="keychain-setup-button"
    >
      {busy ? "Setting up…" : "Set Up Secure Storage"}
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
  .sub strong {
    color: var(--color-fg);
    font-weight: 600;
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
