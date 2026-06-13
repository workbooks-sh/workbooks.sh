<script lang="ts">
  /**
   * LessonOverlay (wb-aakl.20) — the "port → edge → highlight" layer for the
   * coach's learn-more mode. Given the coach's port, the coach element (an
   * obstacle), and a CSS selector for a DOM target, it draws:
   *   • a rounded outline around the live target element, and
   *   • an ORTHOGONAL edge from the port that routes AROUND the coach (up, over
   *     the top, down a side) so it never crosses the coach's text.
   * Portaled to <body> so it escapes the coach's stacking context and renders
   * above the sidebar/titlebar. Re-measures on resize/scroll/target change.
   */
  type Pt = { x: number; y: number };
  let {
    portEl,
    coachEl,
    target,
    edge = true,
  }: { portEl: HTMLElement | null; coachEl: HTMLElement | null; target: string; edge?: boolean } = $props();

  let port = $state<DOMRect | null>(null);
  let coach = $state<DOMRect | null>(null);
  let tgt = $state<DOMRect | null>(null);

  function measure() {
    port = portEl?.getBoundingClientRect() ?? null;
    coach = coachEl?.getBoundingClientRect() ?? null;
    const el = target ? document.querySelector(target) : null;
    tgt = el?.getBoundingClientRect() ?? null;
  }

  $effect(() => {
    void target;
    void portEl;
    void coachEl;
    measure();
    const raf = requestAnimationFrame(measure);
    const ro = new ResizeObserver(measure);
    if (portEl) ro.observe(portEl);
    if (coachEl) ro.observe(coachEl);
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

  function pointToward(from: Pt, to: Pt, dist: number): Pt {
    const dx = to.x - from.x, dy = to.y - from.y;
    const len = Math.hypot(dx, dy) || 1;
    const d = Math.min(dist, len / 2);
    return { x: from.x + (dx / len) * d, y: from.y + (dy / len) * d };
  }
  function roundedPath(pts: Pt[], r = 9): string {
    if (pts.length < 2) return "";
    let d = `M ${pts[0].x} ${pts[0].y}`;
    for (let i = 1; i < pts.length - 1; i++) {
      const a = pointToward(pts[i], pts[i - 1], r);
      const b = pointToward(pts[i], pts[i + 1], r);
      d += ` L ${a.x} ${a.y} Q ${pts[i].x} ${pts[i].y} ${b.x} ${b.y}`;
    }
    const last = pts[pts.length - 1];
    d += ` L ${last.x} ${last.y}`;
    return d;
  }

  const geom = $derived.by(() => {
    if (!port || !tgt) return null;
    const pad = 4;
    const box = { x: tgt.left - pad, y: tgt.top - pad, w: tgt.width + pad * 2, h: tgt.height + pad * 2 };

    const P: Pt = { x: port.left + port.width / 2, y: port.top };
    const tcx = tgt.left + tgt.width / 2;
    const tcy = tgt.top + tgt.height / 2;

    // Without a coach rect, fall back to a straight orthogonal-ish path.
    if (!coach) {
      const T: Pt = { x: tcx, y: P.y < tcy ? tgt.top : tgt.bottom };
      return { path: roundedPath([P, { x: P.x, y: (P.y + T.y) / 2 }, { x: T.x, y: (P.y + T.y) / 2 }, T]), tip: T, box };
    }

    const GAP = 18;
    const topY = coach.top - GAP;
    const pts: Pt[] = [P, { x: P.x, y: topY }];
    let T: Pt;
    if (tcy <= coach.top) {
      // Target is above the coach (e.g. titlebar): over the top, drop in.
      T = { x: tcx, y: tgt.bottom };
      pts.push({ x: T.x, y: topY });
    } else {
      // Target beside/below: over the top, down the nearer side, in from the side.
      const leftSide = tcx < (coach.left + coach.right) / 2;
      const sideX = leftSide ? coach.left - GAP : coach.right + GAP;
      T = { x: leftSide ? tgt.right : tgt.left, y: tcy };
      pts.push({ x: sideX, y: topY });
      pts.push({ x: sideX, y: T.y });
    }
    pts.push(T);
    return { path: roundedPath(pts), tip: T, box };
  });

  function portal(node: Element) {
    document.body.appendChild(node);
    return { destroy: () => node.remove() };
  }
</script>

{#if geom}
  <svg use:portal class="lesson-overlay" aria-hidden="true">
    <rect class="hl" x={geom.box.x} y={geom.box.y} width={geom.box.w} height={geom.box.h} rx="9" />
    {#if edge}
      <path class="edge" d={geom.path} />
      <circle class="tip" cx={geom.tip.x} cy={geom.tip.y} r="3.5" />
    {/if}
  </svg>
{/if}

<style>
  :global(svg.lesson-overlay) {
    position: fixed;
    inset: 0;
    width: 100vw;
    height: 100vh;
    pointer-events: none;
    z-index: 1200; /* portaled to body — above all chrome */
    overflow: visible;
  }
  :global(svg.lesson-overlay) .hl {
    fill: color-mix(in srgb, var(--color-brand) 8%, transparent);
    stroke: var(--color-brand);
    stroke-width: 1.5;
  }
  :global(svg.lesson-overlay) .edge {
    fill: none;
    stroke: var(--color-brand);
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
    stroke-dasharray: 5 6;
    animation: edge-dash 0.6s linear infinite;
  }
  :global(svg.lesson-overlay) .tip { fill: var(--color-brand); }
  @keyframes edge-dash { to { stroke-dashoffset: -11; } }
  @media (prefers-reduced-motion: reduce) {
    :global(svg.lesson-overlay) .edge { animation: none; }
  }
</style>
