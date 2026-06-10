<script>
  import { build } from "./build.svelte.js";
  let { name, band = false, children } = $props();
  let shown = $derived(!!build.shown[name]);
</script>
<section class="ch" class:band class:building={!shown} class:built={shown} id={name}>
  <div class="in">{@render children()}</div>
</section>
<style>
  .ch{padding:clamp(3rem,7vw,5.5rem) 0}
  .band{background:var(--bg2)}
  .in{max-width:var(--maxw);margin:0 auto;padding:0 var(--edge);position:relative}
  .building .in > :global(*){opacity:0}
  .building .in{min-height:200px}
  .building .in::after{content:"";position:absolute;inset:0;border-radius:18px;
    background:linear-gradient(100deg,var(--bg2) 22%,var(--hair) 48%,var(--bg2) 72%);background-size:240% 100%;animation:shim 1.15s linear infinite}
  :global([data-theme="dark"]) .building .in::after{background:linear-gradient(100deg,#161619 22%,#26262b 48%,#161619 72%);background-size:240% 100%}
  @keyframes shim{to{background-position:-240% 0}}
  .built .in > :global(*){animation:rise .6s cubic-bezier(.2,.7,.2,1) both}
  @keyframes rise{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:none}}
</style>
