<script>
  import Section from "../lib/Section.svelte";
  import Button from "../lib/Button.svelte";
  let copied = $state(false);
  function copy(){ navigator.clipboard?.writeText("curl -fsSL workbooks.sh/cli.sh | sh"); copied=true; setTimeout(()=>copied=false,1400); }
</script>
<Section name="get">
  <div class="card">
    <h2 class="big mixed">Make <em>a workbook.</em></h2>
    <p class="sub mono">free · macOS · Windows · Linux</p>
    <div class="cta"><Button variant="ink" lg href="https://github.com/workbooks-sh/workbooks.sh/releases">Download the app</Button><Button variant="text" href="/docs">Browse the docs →</Button></div>
    <div class="term mono">
      <button class="cp" onclick={copy}>{copied ? "copied" : "copy"}</button>
      <div><span class="p">$</span> curl -fsSL workbooks.sh/cli.sh | sh</div>
    </div>
  </div>
</Section>
<style>
  .card{background:var(--card);border:1px solid var(--hair);border-radius:24px;box-shadow:var(--shadow);
    padding:clamp(2.4rem,5vw,4rem);text-align:center;max-width:760px;margin:0 auto}
  .big{font-size:clamp(2.2rem,4.5vw,3.4rem)}
  .sub{font-size:.78rem;color:var(--ink3);margin:var(--s2) 0 var(--s5)}
  .cta{display:flex;gap:var(--s3);justify-content:center;flex-wrap:wrap;margin-bottom:var(--s5)}
  .term{position:relative;background:#0b0b0d;border-radius:12px;padding:.9rem 1.1rem;font-size:.84rem;color:#e8e8e4;max-width:30rem;margin:0 auto;text-align:left}
  :global([data-theme="dark"]) .term{border:1px solid #26262b}
  .term .p{color:var(--green)}
  .cp{position:absolute;right:.7rem;top:.7rem;font-size:.66rem;background:#26262b;color:#a9aab1;border:0;border-radius:7px;padding:.28rem .55rem;cursor:pointer;font-family:inherit}
  .cp:hover{color:#fff}
  .mono{font-family:var(--mono)}
</style>
