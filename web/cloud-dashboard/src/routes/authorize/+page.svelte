<script>
  import { enhance } from '$app/forms';
  import DnaStrip from '$lib/DnaStrip.svelte';

  let { data } = $props();
  let busy = $state(false);
</script>

<svelte:head><title>Authorize Workbooks</title></svelte:head>

<div class="wrap">
  <div class="aurora" aria-hidden="true"></div>

  <form
    method="POST"
    class="card"
    use:enhance={() => {
      busy = true;
      return async ({ update }) => {
        await update();
        busy = false;
      };
    }}
  >
    <input type="hidden" name="flow" value={data.flow} />

    <div class="mark" aria-hidden="true">✦</div>
    <h1>Authorize this device</h1>
    <p class="lede">
      Workbooks for desktop wants to sign in to your account{#if data.email}
        as <strong>{data.email}</strong>{/if}.
    </p>

    <div class="actions">
      <button type="submit" formaction="?/approve" class="approve" disabled={busy}>
        {busy ? 'Authorizing…' : 'Approve'}
      </button>
      <button type="submit" formaction="?/cancel" class="cancel" disabled={busy}>Cancel</button>
    </div>

    <p class="fine">Approving signs this device into your Workbooks account.</p>
  </form>

  <div class="dna-edge"><DnaStrip height={14} /></div>
</div>

<style>
  .wrap {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    overflow: hidden;
    background: #faf8f1;
    color: #121316;
    font-family: 'Geist', ui-sans-serif, system-ui, -apple-system, sans-serif;
  }
  .aurora {
    position: absolute;
    inset: 0;
    pointer-events: none;
    opacity: 0.85;
    background:
      radial-gradient(42rem 28rem at 50% -10%, rgba(168, 212, 240, 0.42), transparent 70%),
      radial-gradient(32rem 24rem at 14% 4%, rgba(243, 197, 163, 0.38), transparent 72%),
      radial-gradient(32rem 24rem at 86% 2%, rgba(174, 229, 194, 0.34), transparent 72%),
      radial-gradient(30rem 22rem at 78% 96%, rgba(212, 201, 240, 0.3), transparent 74%);
  }
  .card {
    position: relative;
    z-index: 1;
    width: min(92vw, 460px);
    padding: 44px 44px 40px;
    text-align: center;
    background: #fffdf8;
    border: 1px solid rgba(18, 19, 22, 0.08);
    border-radius: 22px;
    box-shadow:
      0 1px 2px rgba(18, 19, 22, 0.06),
      0 18px 44px rgba(18, 19, 22, 0.16);
    animation: rise 520ms cubic-bezier(0.22, 1, 0.36, 1) both;
  }
  .mark {
    width: 66px;
    height: 66px;
    margin: 0 auto 24px;
    border-radius: 19px;
    display: grid;
    place-items: center;
    font-size: 30px;
    background: linear-gradient(135deg, #f3c5a3, #a8d4f0 48%, #d4c9f0);
    box-shadow:
      0 1px 2px rgba(18, 19, 22, 0.06),
      0 14px 34px rgba(18, 19, 22, 0.14);
  }
  h1 {
    margin: 0 0 12px;
    font-size: 1.9rem;
    font-weight: 600;
    letter-spacing: -0.02em;
  }
  .lede {
    margin: 0 auto 28px;
    max-width: 34ch;
    font-size: 0.95rem;
    line-height: 1.55;
    color: rgba(18, 19, 22, 0.68);
  }
  .lede strong {
    color: #121316;
    font-weight: 600;
  }
  .actions {
    display: flex;
    gap: 10px;
    justify-content: center;
  }
  .approve,
  .cancel {
    padding: 12px 26px;
    border-radius: 12px;
    font-family: inherit;
    font-size: 0.95rem;
    font-weight: 600;
    cursor: pointer;
    transition:
      transform 200ms cubic-bezier(0.22, 1.2, 0.36, 1),
      box-shadow 220ms ease;
  }
  .approve {
    border: 1px solid #121316;
    background: #121316;
    color: #faf8f1;
  }
  .approve:hover:not(:disabled) {
    transform: translateY(-2px);
    box-shadow: 0 10px 26px rgba(18, 19, 22, 0.2);
  }
  .cancel {
    border: 1px solid rgba(18, 19, 22, 0.16);
    background: transparent;
    color: rgba(18, 19, 22, 0.7);
  }
  .cancel:hover:not(:disabled) {
    background: rgba(18, 19, 22, 0.04);
  }
  .approve:disabled,
  .cancel:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }
  .fine {
    margin: 18px 0 0;
    font-size: 0.78rem;
    color: rgba(18, 19, 22, 0.5);
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
