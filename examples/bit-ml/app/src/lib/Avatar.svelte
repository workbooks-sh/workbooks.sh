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
  const src = $derived(
    `https://api.dicebear.com/9.x/open-peeps/svg?seed=${encodeURIComponent(seed ?? name)}`
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
    background: var(--wash);          /* #f5f5f5 circle bg, round-cropped */
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
