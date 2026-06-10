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
    <p class="kicker mono">a new engine for living software</p>
    <h1 class="mixed">This is <em>a workbook.</em></h1>
    <p class="lede">The whole page is one — built and run by an agent on the Workbooks engine, and quietly improving itself while you read. A new way to make software that's <i>alive</i>: working for you, running anywhere, open all the way down.</p>
    <div class="cta">
      <Button variant="ink" lg href="#get">Download the app</Button>
      <Button variant="text" onclick={(e) => { e.preventDefault(); openInsp("elements"); }}>Inspect this page →</Button>
    </div>
    <p class="micro mono">free desktop app · macOS · Windows · Linux</p>
  </div>
</section>
<style>
  .hero{position:relative;overflow:hidden;min-height:min(88vh,800px);display:flex;flex-direction:column;justify-content:center;
    padding:clamp(4rem,9vw,7rem) var(--edge) clamp(3rem,6vw,5rem)}
  :global(.hero .bg){position:absolute;inset:0;width:100%;height:100%;z-index:0;opacity:.55;pointer-events:none;
    -webkit-mask-image:radial-gradient(130% 100% at 50% 30%,#000 0%,transparent 70%);mask-image:radial-gradient(130% 100% at 50% 30%,#000 0%,transparent 70%)}
  .in{position:relative;z-index:1;max-width:48rem;margin:0 auto;width:100%}
  .kicker{font-size:.78rem;color:var(--ink3);margin-bottom:var(--s4)}
  h1{font-size:clamp(3rem,8vw,6rem);line-height:1}
  .lede{font-size:clamp(1.1rem,1.7vw,1.4rem);color:var(--ink2);max-width:46ch;margin:var(--s4) 0 var(--s5);line-height:1.5}
  .lede i{font-style:italic;color:var(--ink)}
  .cta{display:flex;gap:var(--s3);align-items:center;flex-wrap:wrap}
  .micro{font-size:.74rem;color:var(--ink3);margin-top:var(--s4)}
  .building > *{opacity:0} .built > *{animation:rise .6s cubic-bezier(.2,.7,.2,1) both}
  .built > :global(*:nth-child(2)){animation-delay:.08s} .built > :global(*:nth-child(3)){animation-delay:.16s} .built > :global(*:nth-child(n+4)){animation-delay:.24s}
  @keyframes rise{from{opacity:0;transform:translateY(18px)}to{opacity:1;transform:none}}
</style>
