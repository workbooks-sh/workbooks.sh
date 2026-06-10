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
  .lc{position:relative;overflow:hidden;border-radius:18px;padding:1.5rem;min-height:150px;
    display:flex;flex-direction:column;justify-content:flex-end;box-shadow:var(--shadow);border:1px solid transparent}
  .wm{position:absolute;right:-8%;bottom:-26%;width:58%;height:auto;pointer-events:none}
  .body{position:relative;display:flex;flex-direction:column;gap:.5rem}
  .g{font-size:1.3rem;margin-bottom:.2rem;opacity:.9}
  strong{font-size:1.05rem;font-weight:700} .b{font-size:.9rem;opacity:.82;line-height:1.5}
  /* full-color tints; ink text reads on them in both themes; W = a deeper shade */
  .green{background:color-mix(in srgb,var(--green) 22%,var(--card));color:var(--ink)}
  .green .wm{fill:color-mix(in srgb,var(--green) 72%,var(--ink) 8%);opacity:.5}
  .blue{background:color-mix(in srgb,var(--blue) 20%,var(--card));color:var(--ink)}
  .blue .wm{fill:color-mix(in srgb,var(--blue) 70%,var(--ink) 6%);opacity:.5}
  .rose{background:color-mix(in srgb,var(--rose) 18%,var(--card));color:var(--ink)}
  .rose .wm{fill:color-mix(in srgb,var(--rose) 70%,var(--ink) 6%);opacity:.5}
  .ink{background:var(--ink);color:var(--bg)} .ink .wm{fill:color-mix(in srgb,var(--bg) 22%,transparent);opacity:1}
</style>
