<script>
  let { name, size, html, accent = "green", caption = "" } = $props();
</script>
<figure class="wb {accent}">
  <div class="bar"><span class="n mono">{name}</span><span class="s mono">{size} · one file</span></div>
  <iframe title={name} srcdoc={html} loading="lazy"></iframe>
  {#if caption}<figcaption>{caption}</figcaption>{/if}
</figure>
<style>
  .wb{background:var(--card);border:1px solid var(--hair);border-radius:18px;box-shadow:var(--shadow);overflow:hidden;
    display:flex;flex-direction:column;border-top:3px solid var(--c);margin:0}
  .green{--c:var(--green)} .blue{--c:var(--blue)} .rose{--c:var(--rose)}
  .bar{display:flex;align-items:baseline;justify-content:space-between;padding:.8rem 1.1rem .55rem}
  .n{font-size:.84rem;font-weight:500} .s{font-size:.66rem;color:var(--ink3)}
  iframe{width:100%;border:0;flex:1;min-height:300px;background:var(--bg)}
  figcaption{padding:.7rem 1.1rem 1rem;font-size:.82rem;color:var(--ink2)}
  .mono{font-family:var(--mono)}
</style>
