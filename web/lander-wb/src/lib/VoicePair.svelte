<script>let { claim, receipt } = $props();</script>
<div class="vp">
  <div class="claim mixed">{@render claim()}</div>
  {#if receipt}<p class="machine">{@render receipt()}</p>{/if}
</div>
<style>
  .vp{display:flex;flex-direction:column;gap:.9rem;align-items:flex-start}
  .machine{display:inline-flex;align-items:center;gap:.4rem;font-family:var(--mono);font-size:.78rem;color:var(--ink2);
    background:var(--bg2);border:1px solid var(--hair);border-radius:999px;padding:.42rem .85rem}
  :global(.machine .p){color:var(--green-ink);font-weight:700} :global(.machine .c){color:var(--ink3)} :global(.machine .ok){color:var(--green-ink)}
</style>
