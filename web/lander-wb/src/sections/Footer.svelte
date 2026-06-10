<script>
  import { insp } from "../lib/inspector.svelte.js";
  const W="M0 206V0.00231147H69.1194V76L126.393 0L168.946 0.00231147V76L223.295 0L257 0.00231147V183C257 195.703 246.703 206 234 206H116.27L112.626 140.5L41.5 206H0Z";
</script>
<footer class="foot">
  <a class="brand" href="/"><svg viewBox="0 0 257 206" fill="none" aria-label="Workbooks"><path d={W}/></svg><span>Workbooks</span></a>
  {#if insp.changes.length}<span class="live mono"><i></i> maintained live · {insp.changes.length} edits</span>{/if}
  <div class="links mono"><a href="/docs">docs</a><a href="https://github.com/workbooks-sh/workbooks.sh">github</a></div>
</footer>
<style>
  .foot{display:flex;align-items:center;gap:1.2rem;flex-wrap:wrap;max-width:var(--maxw);margin:0 auto;padding:var(--s6) var(--edge) var(--s7)}
  .brand{display:flex;align-items:center;gap:.5rem;font-family:var(--serif);font-weight:600;font-size:1.1rem} .brand svg{height:17px;fill:currentColor}
  .live{display:inline-flex;align-items:center;gap:.4rem;font-size:.72rem;color:var(--green-ink)} .live i{width:7px;height:7px;border-radius:50%;background:var(--green)}
  .links{margin-left:auto;display:flex;gap:1.2rem;font-size:.8rem;color:var(--ink2)} .links a:hover{color:var(--ink)}
</style>
