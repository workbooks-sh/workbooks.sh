<script>
  // §4.5 The receipt — a terminal-skinned block (DARK even in light mode)
  // listing the pipeline trail: assigned → researched → drafted → edited,
  // each row with a time + a commit sha (linking to the commit). The
  // "agent-run" proof artifact, and a good colophon. Always terminal skin.
  // Props: rows [{stage, time, sha, note}] · title.
  let {
    title = 'the receipt',
    rows = [],
  } = $props();
</script>

<div class="receipt" data-theme="terminal">
  <div class="rhead mono">
    <span class="caret">▌</span> {title}
  </div>
  <div class="trail">
    {#each rows as r, i}
      <div class="row mono">
        <span class="stage">{r.stage}</span>
        <span class="time">{r.time}</span>
        {#if r.note}<span class="note">{r.note}</span>{/if}
        <span class="sha">{r.sha}</span>
      </div>
      {#if i < rows.length - 1}<div class="pipe mono">│</div>{/if}
    {/each}
  </div>
</div>

<style>
  .receipt {
    border-radius: var(--r); overflow: hidden;
    background: var(--paper);   /* resolves to terminal #0d0e10 via data-theme */
    color: var(--ink);
    padding: 16px 18px 18px;
    font-family: var(--mono);
  }
  .rhead {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em;
    color: var(--ink-2); margin-bottom: 14px;
  }
  .rhead .caret { color: var(--wire); }

  .trail { display: flex; flex-direction: column; }
  .row {
    display: grid;
    grid-template-columns: 92px 64px 1fr auto;
    align-items: baseline; gap: 12px;
    font-size: 12px; line-height: 1.3;
  }
  .stage { color: var(--ink); font-weight: 500; }
  .time  { color: var(--wire); font-variant-numeric: tabular-nums; }
  .note  { color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sha   { color: var(--ink-3); justify-self: end; }

  .pipe { color: var(--rule); font-size: 12px; line-height: 1; padding: 4px 0 4px 6px; }

  @media (max-width: 520px) {
    .row { grid-template-columns: 80px 56px 1fr; }
    .sha { grid-column: 2 / 4; justify-self: start; }
  }
  /* product chrome: the terminal block sits ON the page like a Linear card */
</style>
