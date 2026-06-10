<script>
  // §4.6 Market strip. A mono single-line band between hairlines:
  //   NVDA +2.4 ▲ · BTC 97,210 ▼ · SOX +1.1 ▲
  // up/down colors, no charts on the front. §4.6: real data only, never
  // placeholder numbers — so in this SPECIMEN the strip carries an explicit
  // mono "· specimen" suffix to flag the numbers as fake (per the brief).
  // Props: items [{sym, val, dir}] where dir ∈ 'up'|'down'.
  let { items = [], specimen = true } = $props();
</script>

<div class="strip">
  <hr class="hair" />
  <div class="line mono">
    {#each items as it, i}<span class="item {it.dir}">{it.sym} {it.val} {it.dir === 'up' ? '▲' : '▼'}</span>{#if i < items.length - 1}<span class="sep">·</span>{/if}{/each}{#if specimen}<span class="tag">· specimen</span>{/if}
  </div>
  <hr class="hair" />
</div>

<style>
  .strip { margin: 4px 0; }
  .line {
    padding: 9px 0;
    font-size: 12px; letter-spacing: 0.02em;
    color: var(--ink-2);
    display: flex; align-items: center; flex-wrap: wrap; gap: 2px;
  }
  .item { font-weight: 500; font-variant-numeric: tabular-nums; }
  .up   { color: var(--up); }
  .down { color: var(--down); }
  .sep  { color: var(--rule); padding: 0 8px; }
  .tag  {
    margin-left: 10px; color: var(--ink-3); font-weight: 400;
    text-transform: uppercase; letter-spacing: 0.06em; font-size: 10px;
  }
</style>
