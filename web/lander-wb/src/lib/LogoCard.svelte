<script>
  let { accent = "green", glyph = "", title = "", children } = $props();
</script>
<div class="lc {accent}">
  <svg class="wm" viewBox="0 0 257 206" aria-hidden="true"><path d="M0 206V0.00231147H69.1194V76L126.393 0L168.946 0.00231147V76L223.295 0L257 0.00231147V183C257 195.703 246.703 206 234 206H116.27L112.626 140.5L41.5 206H0Z"/></svg>
  <div class="body">
    {#if glyph}<span class="g">{glyph}</span>{/if}
    <strong>{title}</strong>
    <span class="b">{@render children()}</span>
  </div>
</div>
<style>
  .lc{position:relative;overflow:hidden;border-radius:20px;padding:var(--pad-card);min-height:190px;
    display:flex;flex-direction:column;justify-content:flex-end;box-shadow:var(--shadow);border:1px solid transparent}
  .wm{position:absolute;right:-8%;bottom:-26%;width:58%;height:auto;pointer-events:none}
  .body{position:relative;display:flex;flex-direction:column;gap:.65rem}
  .g{font-size:1.3rem;margin-bottom:.2rem;opacity:.85}
  strong{font-size:1.05rem;font-weight:700} .b{font-size:.9rem;opacity:.8;line-height:1.5}
  /* SATURATED color backgrounds; the W-mark is the subtle, lighter tone (a soft
     white wash over the fill). Text contrast chosen per color. */
  .green{background:var(--green);color:#093116} .green .wm{fill:#fff;opacity:.26}
  .blue{background:var(--blue);color:#fff} .blue .wm{fill:#fff;opacity:.2}
  .rose{background:var(--rose);color:#fff} .rose .wm{fill:#fff;opacity:.2}
  .ink{background:var(--ink);color:var(--bg)} .ink .wm{fill:currentColor;opacity:.12}
</style>
