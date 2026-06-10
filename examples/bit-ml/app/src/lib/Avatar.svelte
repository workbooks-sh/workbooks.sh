<script>
  // Avatar — the crew are CHARACTERS (DESIGN.md "the crew are characters").
  // OpenPeeps via DiceBear (CC0, deterministic per seed): a round-cropped,
  // gray-circle-backed illustrated face that humanizes the bylines + the org
  // chart. NEVER used for humans — only agents. Fetched, never bundled.
  //   url: https://api.dicebear.com/9.x/open-peeps/svg?seed=<seed>
  // Sizes: sm 28 · md 44 · lg 64. A wire-blue live badge sits on the corner
  // when the agent is working (the live dot, relocated onto the face).
  let { seed, name = seed, size = 'md', live = false } = $props();

  const px = { sm: 28, md: 44, lg: 64 };
  const dim = $derived(px[size] ?? px.md);
  // COLOR (founder: not b/w): DiceBear picks deterministically per seed from
  // these palettes — pastel circle, vivid clothing, natural skin tones. The
  // peeps are the one place the monochrome page gets to have fun.
  const BG = 'b6e3f4,c0aede,ffd5dc,ffdfbf,d1f4d9';
  const CLOTHES = '0a52e0,e05a4e,2e9e6b,e0a82e,7a4988';
  const SKIN = 'ffdbb4,edb98a,d08b5b,ae5d29,694d3d';
  const src = $derived(
    `https://api.dicebear.com/9.x/open-peeps/svg?seed=${encodeURIComponent(seed ?? name)}` +
    `&backgroundType=solid&backgroundColor=${BG}&clothingColor=${CLOTHES}&skinColor=${SKIN}`
  );
</script>

<span class="av {size}" style="--dim:{dim}px">
  <img class="face" {src} alt={name} loading="lazy" width={dim} height={dim} />
  {#if live}<span class="badge" aria-label="live"></span>{/if}
</span>

<style>
  .av {
    position: relative; display: inline-block;
    width: var(--dim); height: var(--dim); flex: 0 0 auto;
  }
  .face {
    width: 100%; height: 100%;
    border-radius: 999px;
    background: var(--wash);          /* fallback while the svg loads */
    object-fit: cover; display: block;
  }
  .badge {
    position: absolute; right: 0; bottom: 0;
    width: 28%; height: 28%; min-width: 8px; min-height: 8px;
    border-radius: 999px;
    background: var(--wire);
    box-shadow: 0 0 0 2px var(--paper);   /* punch through the face cleanly */
    animation: breathe 2.4s ease-in-out infinite;
  }
  @keyframes breathe { 50% { opacity: .45; } }
</style>
