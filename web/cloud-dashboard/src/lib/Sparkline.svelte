<script>
  // Deterministic sparkline (ported from the prototype's spark(seed)).
  let { seed = 1 } = $props();
  const path = (() => {
    let x = 0;
    const pts = [];
    for (let i = 0; i < 14; i++) {
      const v = 8 + Math.abs(Math.sin(seed + i * 0.7)) * 18;
      pts.push([x, 28 - v]);
      x += 6;
    }
    return pts.map((q, i) => (i ? 'L' : 'M') + q[0] + ' ' + q[1].toFixed(1)).join(' ');
  })();
</script>

<svg class="spark" viewBox="0 0 84 30" preserveAspectRatio="none">
  <path d={path} fill="none" stroke="var(--live)" stroke-width="1.5" opacity=".8" />
</svg>
