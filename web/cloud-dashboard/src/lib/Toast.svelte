<script>
  import { toastStore } from '$lib/toastStore.svelte.js';
</script>

<div class="toasts">
  {#each toastStore.all as t (t.id)}
    <div class="toast {t.kind}" onclick={() => toastStore.dismiss(t.id)} role="status">
      <span class="dot {t.kind === 'bad' ? 'pause' : 'run'}"></span>
      <span>{t.msg}</span>
    </div>
  {/each}
</div>

<style>
  .toasts {
    position: fixed;
    bottom: 20px;
    right: 20px;
    z-index: 60;
    display: flex;
    flex-direction: column;
    gap: 10px;
    align-items: flex-end;
  }
  .toast {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 11px 15px;
    background: var(--card);
    border: 2px solid var(--stroke);
    border-radius: 11px;
    box-shadow: 4px 4px 0 var(--shadow);
    color: var(--ink);
    font: 500 13px var(--read);
    cursor: pointer;
    max-width: 340px;
    animation: toast-in 0.16s ease;
  }
  .toast.bad {
    border-color: var(--bad);
  }
  @keyframes toast-in {
    from {
      transform: translateY(8px);
      opacity: 0;
    }
    to {
      transform: translateY(0);
      opacity: 1;
    }
  }
</style>
