<script>
  // Port of WB.dna — a deterministic shuffle of weighted pastel bars, looped to fill the track.
  let { seed = 11, height = 8 } = $props()
  const MIX = [['#f3c5a3', 0.3], ['#aee5c2', 0.24], ['#a8d4f0', 0.2], ['#9fc4e8', 0.14], ['#f2ddb0', 0.12]]

  const bars = $derived.by(() => {
    const out = []
    for (const [c, f] of MIX) {
      const n = f > 0.3 ? 3 : f > 0.12 ? 2 : 1
      for (let j = 0; j < n; j++) out.push([c, f / n])
    }
    let k = seed
    for (let i = out.length - 1; i > 0; i--) {
      k++
      const r = (((Math.sin(k * 127.1) * 43758.5453) % 1) + 1) % 1
      const j = Math.floor(r * (i + 1))
      ;[out[i], out[j]] = [out[j], out[i]]
    }
    return out.concat(out)
  })
</script>

<div class="dna" style="--h:{height}px" aria-hidden="true">
  <div class="track">
    {#each bars as [color, w]}<i style="width:{(w * 50).toFixed(2)}%;background:{color}"></i>{/each}
  </div>
</div>
