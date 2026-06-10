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
    display:flex;flex-direction:column;margin:0}
  .green{--c:var(--green)} .blue{--c:var(--blue)} .rose{--c:var(--rose)}
  .bar{display:flex;align-items:baseline;justify-content:space-between;padding:1.1rem 1.3rem .7rem}
  .n{font-size:.84rem;font-weight:500} .s{font-size:.66rem;color:var(--ink3)}
  iframe{width:100%;border:0;flex:1;min-height:300px;background:var(--bg)}
  figcaption{padding:.9rem 1.3rem 1.3rem;font-size:.84rem;color:var(--ink2);line-height:1.55}
  .mono{font-family:var(--mono)}
</style>
