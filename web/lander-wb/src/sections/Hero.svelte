<script>
  import Ascii from "../lib/Ascii.svelte";
  import Button from "../lib/Button.svelte";
  import { build } from "../lib/build.svelte.js";
  import { openInsp } from "../lib/inspector.svelte.js";
  let shown = $derived(!!build.shown.hero);
</script>
<section class="hero">
  <Ascii klass="bg" dense speed={0.7} />
  <div class="in" class:building={!shown} class:built={shown}>
    <p class="kicker">a new engine for living software</p>
    <h1>This is<br>a workbook.</h1>
    <p class="lede">This whole page is one — built and run by an agent on the Workbooks engine, quietly improving itself as you read. It's a new way to make software that's <em>alive</em>: working for you, running anywhere, open all the way down.</p>
    <div class="cta">
      <Button variant="ink" lg href="#get">Download the app</Button>
      <Button variant="text" onclick={(e) => { e.preventDefault(); openInsp("elements"); }}>Inspect this page →</Button>
    </div>
    <p class="micro">free desktop app · macOS · Windows · Linux</p>
  </div>
</section>
<style>
  .hero{position:relative;overflow:hidden;min-height:min(86vh,760px);display:flex;flex-direction:column;justify-content:center;
    padding:clamp(4rem,9vw,7rem) var(--edge) clamp(3rem,6vw,5rem)}
  :global(.hero .bg){position:absolute;inset:0;width:100%;height:100%;z-index:0;opacity:.58;pointer-events:none;
    -webkit-mask-image:radial-gradient(125% 95% at 50% 32%,#000 0%,transparent 72%);mask-image:radial-gradient(125% 95% at 50% 32%,#000 0%,transparent 72%)}
  .in{position:relative;z-index:1;max-width:46rem}
  .kicker{font-family:var(--mono);font-size:.76rem;color:var(--ink3);margin-bottom:1.4rem}
  h1{font-size:clamp(2.8rem,7vw,5.4rem)}
  .lede{font-size:clamp(1.05rem,1.6vw,1.3rem);color:var(--ink2);max-width:44ch;margin:1.6rem 0 2rem}
  .lede em{font-style:italic;color:var(--ink)}
  .cta{display:flex;gap:1rem;align-items:center;flex-wrap:wrap}
  .micro{font-family:var(--mono);font-size:.74rem;color:var(--ink3);margin-top:1.4rem}
  .building > *{opacity:0} .built > *{animation:rise .6s cubic-bezier(.2,.7,.2,1) both}
  .built > :global(*:nth-child(2)){animation-delay:.08s} .built > :global(*:nth-child(3)){animation-delay:.16s}
  .built > :global(*:nth-child(n+4)){animation-delay:.24s}
  @keyframes rise{from{opacity:0;transform:translateY(18px)}to{opacity:1;transform:none}}
</style>
