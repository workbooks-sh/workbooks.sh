<script lang="ts">
  /**
   * Full-page overlay when the user hasn't signed into Workbooks.
   * Copy avoids naming the underlying auth provider — to the user,
   * this is just "sign in to Workbooks."
   */
  import { LogIn } from "@lucide/svelte";
  import EmptyState from "$lib/network/components/EmptyState.svelte";
  import { auth } from "./store.svelte";

  let signingIn = $state(false);
  let signInError = $state<string | null>(null);

  async function signIn() {
    if (signingIn) return;
    signingIn = true;
    signInError = null;
    try {
      await auth.signIn();
    } catch (e) {
      signInError = e instanceof Error ? e.message : String(e);
    } finally {
      signingIn = false;
    }
  }
</script>

<div class="overlay">
  <EmptyState
    title="Sign in to Workbooks"
    blurb="Workbooks needs an account so you can publish workbooks, message friends, and sync across devices. Sign-in opens in a browser window — come back when it's done."
    glyph="✦"
    hue={190}
  >
    {#snippet cta()}
      <div class="cta-stack">
        <button type="button" class="btn primary" onclick={signIn} disabled={signingIn}>
          <LogIn size={13} strokeWidth={2.25} />
          {signingIn ? "Opening sign-in…" : "Sign in to Workbooks"}
        </button>
        {#if signInError}
          <p class="err">{signInError}</p>
        {/if}
      </div>
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
  .cta-stack {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
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
  .err {
    margin: 0;
    padding: 7px 11px;
    border-radius: 6px;
    background: rgba(220, 60, 60, 0.08);
    border: 1px solid rgba(220, 60, 60, 0.22);
    color: rgb(180, 50, 50);
    font-size: 0.78rem;
    font-weight: 500;
    max-width: 36ch;
    text-align: center;
  }
</style>
