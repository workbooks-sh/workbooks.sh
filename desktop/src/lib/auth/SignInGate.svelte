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
    <div class="mark" aria-hidden="true">
      <svg viewBox="0 0 320 320" xmlns="http://www.w3.org/2000/svg">
        <rect width="320" height="320" rx="72" fill="#121316" />
        <path
          transform="translate(70 108) scale(1.586)"
          fill="#f7f6f1"
          d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z"
        />
      </svg>
    </div>

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

  /* One smooth, diffuse pastel wash from the top that melts into paper — clean, not
   * blobby (the DNA strip carries the multi-pastel pop at the bottom edge). */
  .aurora {
    position: absolute;
    inset: 0;
    pointer-events: none;
    opacity: 0.9;
    background:
      radial-gradient(
        135% 92% at 50% -28%,
        color-mix(in srgb, var(--color-chip-blue) 20%, transparent) 0%,
        color-mix(in srgb, var(--color-chip-lavender) 11%, transparent) 42%,
        transparent 72%
      );
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
    width: 64px;
    height: 64px;
    margin: 0 auto 24px;
    border-radius: 16px;
    box-shadow:
      var(--shadow-pop),
      0 0 0 1px color-mix(in srgb, var(--color-fg) 6%, transparent);
  }
  .mark :global(svg) {
    width: 100%;
    height: 100%;
    display: block;
    border-radius: inherit;
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
