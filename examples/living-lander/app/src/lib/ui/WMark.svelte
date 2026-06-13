<script>
  // ── LIVING MACHINE — the living W mark (canon §3.5 breathe + §4.3 draw) ──
  // The Workbooks "W" as a genuinely-alive element: breathes (the sacred green
  // glow) and can draw itself in on mount (native stroke-dashoffset, NOT
  // DrawSVG). The path geometry is the single source from lib/Wmark.svelte.
  import { onMount } from 'svelte';
  import { breathe as breatheAction, draw } from '../motion.js';

  let {
    size = 28,
    alive = true,        // breathing green glow
    drawIn = false,      // stroke-draw on mount
    class: klass = '',
    ...rest
  } = $props();

  const D =
    'M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z';

  let pathEl = $state(null);

  function aliveAction(node) {
    if (!alive) return {};
    return breatheAction(node);
  }

  onMount(() => {
    if (drawIn && pathEl) draw([pathEl], { duration: 1.4, stagger: 0 });
  });
</script>

<svg
  class={`wmark ${klass}`}
  viewBox="0 0 113.444 65.6002"
  width={size}
  height={(size * 65.6002) / 113.444}
  fill="none"
  use:aliveAction
  {...rest}
>
  {#if drawIn}
    <path
      bind:this={pathEl}
      d={D}
      fill="none"
      stroke="var(--live)"
      stroke-width="2.4"
      stroke-linejoin="round" />
  {:else}
    <path d={D} fill="currentColor" />
  {/if}
</svg>

<style>
  .wmark {
    display: inline-block;
    color: var(--live);
    overflow: visible;
  }
</style>
