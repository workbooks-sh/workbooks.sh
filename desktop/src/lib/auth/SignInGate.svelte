<script lang="ts">
  /**
   * Mandatory sign-in gate — full-screen before the app is reachable. A grand,
   * on-brand welcome: paper field, a soft pastel aurora, one big "Get started", and
   * the signature multi-pastel DNA strip along the bottom edge.
   *
   * Copy reflects the model: the app is FREE and local-first; signing in syncs your
   * account and unlocks the cloud. It never names the underlying auth provider — to
   * the user this is simply "sign in to Workbooks" (one front door, app.workbooks.sh).
   */
  import { SignIn as LogIn } from "phosphor-svelte";
  import DnaStrip from "$lib/components/DnaStrip.svelte";
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

<div class="gate">
  <div class="aurora" aria-hidden="true"></div>

  <div class="card">
    <div class="mark" aria-hidden="true"><span>✦</span></div>

    <h1>Welcome to Workbooks</h1>
    <p class="lede">
      Your workbooks live on your machine — free. Sign in to sync across devices,
      manage your account, and spin up the cloud whenever you're ready.
    </p>

    <button type="button" class="cta" onclick={signIn} disabled={signingIn}>
      <LogIn weight="fill" size={16} />
      {signingIn ? "Opening sign-in…" : "Get started"}
    </button>

    <p class="fine">Free, local-first. Sign-in opens in your browser — come back when it's done.</p>

    {#if signInError ?? auth.lastError}
      <p class="err">{signInError ?? auth.lastError}</p>
    {/if}
  </div>

  <div class="dna-edge"><DnaStrip height={14} /></div>
</div>

<style>
  .gate {
    position: fixed;
    inset: 0;
    z-index: 1000;
    background: var(--color-page);
    display: grid;
    place-items: center;
    overflow: hidden;
  }

  /* Soft pastel aurora — the brand glow, top-weighted so the card floats on it. */
  .aurora {
    position: absolute;
    inset: 0;
    pointer-events: none;
    opacity: 0.85;
    background:
      radial-gradient(42rem 28rem at 50% -10%, color-mix(in srgb, var(--color-chip-blue) 42%, transparent), transparent 70%),
      radial-gradient(32rem 24rem at 14% 4%, color-mix(in srgb, var(--color-chip-peach) 38%, transparent), transparent 72%),
      radial-gradient(32rem 24rem at 86% 2%, color-mix(in srgb, var(--color-chip-green) 34%, transparent), transparent 72%),
      radial-gradient(30rem 22rem at 78% 96%, color-mix(in srgb, var(--color-chip-lavender) 30%, transparent), transparent 74%);
  }

  .card {
    position: relative;
    z-index: 1;
    width: min(92vw, 460px);
    padding: 44px 44px 40px;
    text-align: center;
    background: color-mix(in srgb, var(--color-surface, var(--color-page)) 88%, var(--color-page));
    border: 1px solid color-mix(in srgb, var(--color-fg) 8%, transparent);
    border-radius: 22px;
    box-shadow: var(--shadow-pop);
    animation: rise 520ms cubic-bezier(0.22, 1, 0.36, 1) both;
  }

  .mark {
    width: 66px;
    height: 66px;
    margin: 0 auto 24px;
    border-radius: 19px;
    display: grid;
    place-items: center;
    background: linear-gradient(
      135deg,
      var(--color-chip-peach),
      var(--color-chip-blue) 48%,
      var(--color-chip-lavender)
    );
    box-shadow: var(--shadow-pop);
  }
  .mark span {
    font-size: 30px;
    line-height: 1;
    color: var(--color-fg);
  }

  h1 {
    margin: 0 0 12px;
    font-family: var(--font-sans);
    font-size: 2.05rem;
    font-weight: 600;
    letter-spacing: -0.02em;
    color: var(--color-fg);
  }

  .lede {
    margin: 0 auto 28px;
    max-width: 34ch;
    font-size: 0.95rem;
    line-height: 1.55;
    color: color-mix(in srgb, var(--color-fg) 68%, transparent);
  }

  .cta {
    display: inline-flex;
    align-items: center;
    gap: 9px;
    padding: 13px 30px;
    border-radius: 12px;
    border: 1px solid var(--color-fg);
    background: var(--color-fg);
    color: var(--color-page);
    font-family: var(--font-sans);
    font-size: 1rem;
    font-weight: 600;
    cursor: pointer;
    transition:
      transform 200ms cubic-bezier(0.22, 1.2, 0.36, 1),
      box-shadow 220ms ease;
  }
  .cta:hover:not(:disabled) {
    transform: translateY(-2px);
    box-shadow: 0 10px 26px rgba(18, 19, 22, 0.2);
  }
  .cta:active:not(:disabled) {
    transform: translateY(0);
  }
  .cta:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .fine {
    margin: 18px 0 0;
    font-size: 0.78rem;
    color: color-mix(in srgb, var(--color-fg) 52%, transparent);
  }

  .err {
    margin: 16px auto 0;
    padding: 8px 12px;
    max-width: 36ch;
    border-radius: 9px;
    background: rgba(220, 60, 60, 0.08);
    border: 1px solid rgba(220, 60, 60, 0.22);
    color: rgb(180, 50, 50);
    font-size: 0.78rem;
    font-weight: 500;
  }

  .dna-edge {
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    z-index: 1;
  }

  @keyframes rise {
    from {
      opacity: 0;
      transform: translateY(14px) scale(0.985);
    }
    to {
      opacity: 1;
      transform: none;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .card {
      animation: none;
    }
  }
</style>
