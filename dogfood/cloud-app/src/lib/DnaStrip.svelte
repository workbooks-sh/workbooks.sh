<script>
  // Moving DNA strip — ported from the docs/learn sidebar (web/learn/learn.js `dnaSegs`).
  // The pastel DNA family in weighted proportions, shuffled by seed, drifting slowly.
  const MIX = [['#f3c5a3', 0.30], ['#aee5c2', 0.24], ['#a8d4f0', 0.20], ['#9fc4e8', 0.14], ['#f2ddb0', 0.12]];
  let { seed = 13, height = 12 } = $props();

  function segs(mix, s) {
    const out = [];
    let k = s;
    for (const [c, f] of mix) {
      const n = f > 0.3 ? 3 : f > 0.12 ? 2 : 1;
      for (let j = 0; j < n; j++) out.push([c, f / n]);
    }
    for (let i = out.length - 1; i > 0; i--) {
      k++;
      const r = ((((Math.sin(k * 127.1) * 43758.5453) % 1) + 1) % 1);
      const j = Math.floor(r * (i + 1));
      [out[i], out[j]] = [out[j], out[i]];
    }
    return out;
  }
  const bars = segs(MIX, seed);
  // duplicate for a seamless translateX(-50%) loop
  const loop = [...bars, ...bars];
</script>

<div class="dna" style="--h:{height}px" aria-hidden="true">
  <div class="track">
    {#each loop as [c, w], i (i)}
      <i style="width:{(w * 50).toFixed(2)}%;background:{c}"></i>
    {/each}
  </div>
</div>

<style>
  .dna { height: var(--h); border-radius: 4px; overflow: hidden; }
  .track { display: flex; height: 100%; width: 200%; animation: drift 52s linear infinite; }
  .track i { display: block; height: 100%; }
  @keyframes drift { to { transform: translateX(-50%); } }
  @media (prefers-reduced-motion: reduce) { .track { animation: none; } }
</style>
