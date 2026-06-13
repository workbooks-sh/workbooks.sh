<script lang="ts">
  /**
   * LessonOverlay (wb-aakl.20) — the "port → edge → highlight" layer for the
   * coach's learn-more mode. Given a port element (a node-port box on the
   * coach) and a CSS selector for a DOM target, it draws:
   *   • a rounded outline around the live target element, and
   *   • a routed edge from the port to the target.
   * Full-viewport fixed SVG, pointer-events:none, above the chrome so the
   * outline reads over the titlebar too. Re-measures on resize/scroll and
   * whenever the target changes.
   *
   * (Edge is a smooth vertical bezier — the node-port aesthetic without the
   * heavy elkjs routing dep; swap to ELK if we ever route many edges.)
   */
  let {
    portEl,
    target,
    edge = true,
  }: { portEl: HTMLElement | null; target: string; edge?: boolean } = $props();

  let port = $state<DOMRect | null>(null);
  let tgt = $state<DOMRect | null>(null);

  function measure() {
    port = portEl?.getBoundingClientRect() ?? null;
    const el = target ? document.querySelector(target) : null;
    tgt = el?.getBoundingClientRect() ?? null;
  }

  $effect(() => {
    // Reading target + portEl re-runs this when the lesson changes.
    void target;
    void portEl;
    measure();
    const raf = requestAnimationFrame(measure); // after DOM settles
    const ro = new ResizeObserver(measure);
    if (portEl) ro.observe(portEl);
    const onMove = () => measure();
    window.addEventListener("resize", onMove);
    window.addEventListener("scroll", onMove, true);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      window.removeEventListener("resize", onMove);
      window.removeEventListener("scroll", onMove, true);
    };
  });

  const geom = $derived.by(() => {
    if (!port || !tgt) return null;
    const p = { x: port.left + port.width / 2, y: port.top + port.height / 2 };
    const tcx = tgt.left + tgt.width / 2;
    const tcy = tgt.top + tgt.height / 2;
    // Enter the target on the edge facing the port.
    const t = { x: tcx, y: p.y < tcy ? tgt.top : tgt.bottom };
    const dy = t.y - p.y;
    const path = `M ${p.x} ${p.y} C ${p.x} ${p.y + dy * 0.45} ${t.x} ${t.y - dy * 0.45} ${t.x} ${t.y}`;
    const pad = 4;
    return {
      path,
      tip: t,
      box: { x: tgt.left - pad, y: tgt.top - pad, w: tgt.width + pad * 2, h: tgt.height + pad * 2 },
    };
  });
</script>

{#if geom}
  <svg class="lesson-overlay" aria-hidden="true">
    <rect
      class="hl"
      x={geom.box.x}
      y={geom.box.y}
      width={geom.box.w}
      height={geom.box.h}
      rx="9"
    />
    {#if edge}
      <path class="edge" d={geom.path} />
      <circle class="tip" cx={geom.tip.x} cy={geom.tip.y} r="3.5" />
    {/if}
  </svg>
{/if}

<style>
  .lesson-overlay {
    position: fixed;
    inset: 0;
    width: 100vw;
    height: 100vh;
    pointer-events: none;
    z-index: 250; /* above the titlebar (200) so the outline reads over it */
    overflow: visible;
  }
  .hl {
    fill: color-mix(in srgb, var(--color-brand) 8%, transparent);
    stroke: var(--color-brand);
    stroke-width: 1.5;
    animation: hl-in 0.22s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .edge {
    fill: none;
    stroke: var(--color-brand);
    stroke-width: 2;
    stroke-linecap: round;
    stroke-dasharray: 5 6;
    animation: edge-dash 0.6s linear infinite;
  }
  .tip { fill: var(--color-brand); }
  @keyframes edge-dash { to { stroke-dashoffset: -11; } }
  @keyframes hl-in {
    from { opacity: 0; }
    to { opacity: 1; }
  }
  @media (prefers-reduced-motion: reduce) {
    .edge { animation: none; }
  }
</style>
