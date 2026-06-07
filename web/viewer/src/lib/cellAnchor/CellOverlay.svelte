<script lang="ts">
  /**
   * Cell overlay — invisible click-catcher rects positioned over
   * every known cell. Click → emits onCellClick(id). Hover → highlights
   * the cell with a thin ring and emits onCellHover(id).
   *
   * Sits above the iframe (pointer-events: auto on the catchers
   * themselves, none on the parent so the workbook still receives
   * scroll + non-comment interactions through gaps between cells).
   *
   * Cells that already have unresolved comments get a small pin
   * badge in the top-right corner with the count.
   */
  import type { CellRect } from "./observer.svelte";

  let {
    rects,
    /** Map<cell_id, count of open comments anchored to it>. Cells
     *  not in this map render without a badge. */
    commentCounts = new Map<string, number>(),
    /** Cell ids with stranded anchors — render with a warning tint. */
    stranded = new Set<string>(),
    onCellClick,
    onCellHover,
  }: {
    rects: Map<string, CellRect>;
    commentCounts?: Map<string, number>;
    stranded?: Set<string>;
    onCellClick: (id: string) => void;
    onCellHover: (id: string | null) => void;
  } = $props();

  let hovered = $state<string | null>(null);

  function setHover(id: string | null) {
    if (hovered === id) return;
    hovered = id;
    onCellHover(id);
  }
</script>

<div class="cell-overlay" aria-hidden="true">
  {#each rects.entries() as [id, r] (id)}
    {#if r.inView}
      <button
        type="button"
        class="catcher"
        class:hovered={hovered === id}
        class:has-comments={(commentCounts.get(id) ?? 0) > 0}
        class:stranded={stranded.has(id)}
        style:left={`${r.x}px`}
        style:top={`${r.y}px`}
        style:width={`${r.width}px`}
        style:height={`${r.height}px`}
        aria-label={`Comment on ${id}`}
        onpointerenter={() => setHover(id)}
        onpointerleave={() => setHover(null)}
        onclick={() => onCellClick(id)}
      >
        {#if (commentCounts.get(id) ?? 0) > 0}
          <span class="pin">{commentCounts.get(id)}</span>
        {/if}
      </button>
    {/if}
  {/each}
</div>

<style>
  /* The overlay div itself is transparent + pointer-events: none so
     the workbook keeps receiving native events through the gaps
     between catchers. Catchers themselves enable pointer-events so
     clicks land on them. */
  .cell-overlay {
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 45;
  }
  .catcher {
    position: absolute;
    background: transparent;
    border: 1px solid transparent;
    border-radius: 4px;
    pointer-events: auto;
    cursor: pointer;
    padding: 0;
    transition: border-color 0.1s ease, background 0.1s ease;
  }
  .catcher:hover,
  .catcher.hovered {
    border-color: rgba(99, 102, 241, 0.55);  /* indigo-500 @ 55% */
    background: rgba(99, 102, 241, 0.06);
  }
  .catcher.has-comments {
    border-color: rgba(245, 158, 11, 0.55);  /* amber-500 — has open comments */
  }
  .catcher.stranded {
    border-color: rgba(239, 68, 68, 0.6);    /* rose-500 — stranded anchor */
  }
  /* Hide catcher rings when not interacting unless they have signal
     (comments / stranded). Otherwise the page is a checkerboard. */
  .catcher:not(:hover):not(.hovered):not(.has-comments):not(.stranded) {
    border-color: transparent;
    background: transparent;
  }
  .pin {
    position: absolute;
    top: -8px;
    right: -8px;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    border-radius: 999px;
    background: #f59e0b;
    color: #18181b;
    font-size: 0.7rem;
    font-weight: 700;
    line-height: 18px;
    text-align: center;
    box-shadow: 0 2px 4px rgba(0,0,0,0.35);
    font-family: ui-sans-serif, system-ui, sans-serif;
  }
  .catcher.stranded .pin {
    background: #ef4444;
    color: #fff;
  }
</style>
