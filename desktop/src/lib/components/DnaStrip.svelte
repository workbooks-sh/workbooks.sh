<script lang="ts">
  /**
   * The multi-pastel "DNA" strip — the brand's signature edge motif (ported from the
   * cloud dashboard / learn sidebar). The pastel family in weighted proportions,
   * shuffled by a deterministic seed (Math.sin, no RNG), drifting slowly. Decorative.
   */
  const MIX: Array<[string, number]> = [
    ["#f3c5a3", 0.3], // peach
    ["#aee5c2", 0.24], // mint
    ["#a8d4f0", 0.2], // sky
    ["#9fc4e8", 0.14], // blue
    ["#f2ddb0", 0.12], // cream
  ];

  let { seed = 13, height = 12 }: { seed?: number; height?: number } = $props();

  function segs(mix: Array<[string, number]>, s: number): Array<[string, number]> {
    const out: Array<[string, number]> = [];
    for (const [c, f] of mix) {
      const n = f > 0.3 ? 3 : f > 0.12 ? 2 : 1;
      for (let j = 0; j < n; j++) out.push([c, f / n]);
    }
    let k = s;
    for (let i = out.length - 1; i > 0; i--) {
      k++;
      const r = (((Math.sin(k * 127.1) * 43758.5453) % 1) + 1) % 1;
      const j = Math.floor(r * (i + 1));
      [out[i], out[j]] = [out[j], out[i]];
    }
    return out;
  }

  const loop = (() => {
    const bars = segs(MIX, seed);
    return [...bars, ...bars]; // duplicate for a seamless translateX(-50%) loop
  })();
</script>

<div class="dna" style="--h:{height}px" aria-hidden="true">
  <div class="track">
    {#each loop as [c, w], i (i)}
      <i style="width:{(w * 50).toFixed(2)}%;background:{c}"></i>
    {/each}
  </div>
</div>

<style>
  .dna {
    height: var(--h);
    overflow: hidden;
  }
  .track {
    display: flex;
    height: 100%;
    width: 200%;
    animation: drift 52s linear infinite;
  }
  .track i {
    display: block;
    height: 100%;
  }
  @keyframes drift {
    to {
      transform: translateX(-50%);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .track {
      animation: none;
    }
  }
</style>
