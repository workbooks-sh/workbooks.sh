<script lang="ts">
  /**
   * TintArc — a hue arc that sits at the top of an item's context menu
   * (wb-5fl.14). Drag the thumb along the arc to recolor the item; only
   * the hue moves — saturation/lightness are fixed at values that read
   * on both light and dark themes. "Auto" returns to the hashed default.
   */
  import { tints, tintFor } from "$lib/ui/tint.svelte";

  let { name }: { name: string } = $props();

  const W = 168;
  const H = 86;
  const CX = W / 2;
  const CY = 78;
  const R = 62;
  const SEGS = 36;
  const SAT = 68;
  const LIG = 52;

  function hueAt(t: number): number {
    return Math.round(t * 330); // 0..330 — skip the red wrap-around dupe
  }
  function colorAt(t: number): string {
    return `hsl(${hueAt(t)} ${SAT}% ${LIG}%)`;
  }
  /** Point on the arc for t∈[0,1], sweeping left → right over the top. */
  function pos(t: number): { x: number; y: number } {
    const a = Math.PI * (1 - t);
    return { x: CX + R * Math.cos(a), y: CY - R * Math.sin(a) };
  }

  /** Current override parsed back to t, or null when on auto. */
  const currentT = $derived.by(() => {
    const o = tints.overrides[name];
    if (!o) return null;
    const m = o.match(/^hsl\((\d+)/);
    return m ? Math.min(1, Number(m[1]) / 330) : null;
  });

  let dragging = $state(false);

  function fromPointer(e: PointerEvent, el: SVGSVGElement) {
    const r = el.getBoundingClientRect();
    const x = e.clientX - r.left - CX;
    const y = CY - (e.clientY - r.top);
    let a = Math.atan2(Math.max(0, y), x); // clamp below-arc to ends
    a = Math.min(Math.PI, Math.max(0, a));
    const t = 1 - a / Math.PI;
    tints.set(name, colorAt(t));
  }

  function down(e: PointerEvent) {
    dragging = true;
    const el = e.currentTarget as SVGSVGElement;
    el.setPointerCapture(e.pointerId);
    fromPointer(e, el);
  }
  function move(e: PointerEvent) {
    if (dragging) fromPointer(e, e.currentTarget as SVGSVGElement);
  }

  const thumb = $derived(pos(currentT ?? 0.5));
</script>

<div class="tint-arc">
  <svg
    width={W}
    height={H}
    viewBox="0 0 {W} {H}"
    role="slider"
    aria-label="Color"
    aria-valuemin={0}
    aria-valuemax={330}
    aria-valuenow={currentT === null ? undefined : hueAt(currentT)}
    tabindex="-1"
    onpointerdown={down}
    onpointermove={move}
    onpointerup={() => (dragging = false)}
  >
    {#each Array.from({ length: SEGS }, (_, i) => i) as i (i)}
      {@const t0 = i / SEGS}
      {@const t1 = (i + 1) / SEGS}
      {@const p0 = pos(t0)}
      {@const p1 = pos(t1)}
      <line
        x1={p0.x}
        y1={p0.y}
        x2={p1.x}
        y2={p1.y}
        stroke={colorAt((t0 + t1) / 2)}
        stroke-width="10"
        stroke-linecap="round"
      />
    {/each}
    {#if currentT !== null}
      <circle
        cx={thumb.x}
        cy={thumb.y}
        r="8.5"
        fill={colorAt(currentT)}
        stroke="var(--color-surface)"
        stroke-width="3"
        class="thumb"
      />
    {/if}
  </svg>
  <button
    type="button"
    class="auto"
    class:on={currentT === null}
    onclick={() => tints.clear(name)}
  >
    <span class="swatch" style="background: {tintFor(name)};"></span>
    Auto
  </button>
</div>

<style>
  .tint-arc {
    position: relative;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 4px 4px 2px;
    margin-bottom: 2px;
    border-bottom: 1px solid var(--color-border);
    user-select: none;
    -webkit-user-select: none;
  }
  svg {
    display: block;
    cursor: crosshair;
    touch-action: none;
  }
  .thumb {
    filter: drop-shadow(0 1px 2px rgba(15, 15, 15, 0.3));
    pointer-events: none;
  }
  /* "Auto" chip nests inside the arc's hollow. */
  .auto {
    position: absolute;
    bottom: 8px;
    left: 50%;
    transform: translateX(-50%);
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 9px;
    border: 1px solid var(--color-border);
    border-radius: 999px;
    background: var(--color-surface);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 11px;
    cursor: pointer;
  }
  .auto:hover { color: var(--color-fg); border-color: var(--color-border-strong); }
  .auto.on { color: var(--color-fg); }
  .swatch {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    flex-shrink: 0;
  }
</style>
