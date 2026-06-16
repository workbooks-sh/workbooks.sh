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
    <h1>Authorize this device</h1>
    <p class="lede">
      Workbooks for desktop wants to sign in to your account{#if data.email}{' '}as
      <strong>{data.email}</strong>{/if}.
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
  /* One smooth diffuse wash from the top — clean, not blobby. */
  .aurora {
    position: absolute;
    inset: 0;
    pointer-events: none;
    opacity: 0.9;
    background: radial-gradient(
      135% 92% at 50% -28%,
      rgba(168, 212, 240, 0.22) 0%,
      rgba(212, 201, 240, 0.12) 42%,
      transparent 72%
    );
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
    width: 64px;
    height: 64px;
    margin: 0 auto 24px;
    border-radius: 16px;
    box-shadow:
      0 1px 2px rgba(18, 19, 22, 0.06),
      0 14px 34px rgba(18, 19, 22, 0.16),
      0 0 0 1px rgba(18, 19, 22, 0.06);
  }
  .mark :global(svg) {
    width: 100%;
    height: 100%;
    display: block;
    border-radius: inherit;
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
