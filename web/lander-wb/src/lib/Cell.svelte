<script>let { accent = "green", glyph = "", title = "", children } = $props();</script>
<div class="cell {accent}">
  {#if glyph}<span class="g">{glyph}</span>{/if}
  <strong>{title}</strong>
  <span class="b">{@render children()}</span>
</div>
<style>
  .cell{display:flex;flex-direction:column;gap:.5rem;background:var(--card);border:1px solid var(--hair);
    border-radius:16px;padding:1.2rem 1.3rem;box-shadow:var(--shadow);position:relative;overflow:hidden}
  .cell::before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--c)}
  .green{--c:var(--green)} .blue{--c:var(--blue)} .rose{--c:var(--rose)} .ink{--c:var(--ink)}
  .g{width:38px;height:38px;display:grid;place-items:center;border-radius:11px;font-size:1.1rem;
    background:color-mix(in srgb,var(--c) 14%,var(--card));color:var(--c)}
  strong{font-size:1rem} .b{color:var(--ink2);font-size:.88rem}
</style>
