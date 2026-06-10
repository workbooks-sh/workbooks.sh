<script lang="ts">
  /**
   * DropOverlay — the doc-area drop surface for shell drag-and-drop
   * (epic wb-5fl). Mounts over the main content; renders only while a
   * shell drag is live (dnd.payload set).
   *
   * Zones (canon): the outer ~22% on each side is the SPLIT zone —
   * preview is a translucent brand wash filling the half the new pane
   * would take. Everything between is the OPEN-HERE zone — preview is
   * an inset ring over the hovered pane + a pill naming the action.
   * Edge = give it its own space; center = give it to that surface.
   */
  import { dnd } from "$lib/ui/dnd.svelte";
  import { panes } from "$lib/viewer/panes.svelte";
  import { tabs } from "$lib/tabs/store.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";

  const EDGE = 0.22;

  let hostEl: HTMLDivElement | undefined = $state();
  let zone = $state<"left" | "right" | "center" | null>(null);
  let paneIdx = $state(0);

  /** Fractional left/width of the hovered pane (for the center ring). */
  const paneRect = $derived.by(() => {
    const sizes = panes.isSplit ? panes.sizes : [1];
    const i = Math.min(paneIdx, sizes.length - 1);
    const left = sizes.slice(0, i).reduce((a, b) => a + b, 0);
    return { left, width: sizes[i] };
  });

  function track(e: DragEvent) {
    if (!dnd.payload || !hostEl) return;
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    const r = hostEl.getBoundingClientRect();
    const fx = (e.clientX - r.left) / r.width;
    if (fx < EDGE) zone = "left";
    else if (fx > 1 - EDGE) zone = "right";
    else {
      zone = "center";
      const sizes = panes.isSplit ? panes.sizes : [1];
      let acc = 0;
      paneIdx = sizes.length - 1;
      for (let i = 0; i < sizes.length; i++) {
        acc += sizes[i];
        if (fx <= acc) {
          paneIdx = i;
          break;
        }
      }
    }
  }

  function leave(e: DragEvent) {
    // Only clear when actually exiting the host (dragleave fires on
    // child transitions too).
    if (e.target === hostEl) zone = null;
  }

  async function drop(e: DragEvent) {
    e.preventDefault();
    const z = zone;
    zone = null;
    const p = dnd.payload;
    if (!z || !p) {
      dnd.end();
      return;
    }

    // A dragged tab is already open — route its existing id. Anything
    // else opens (or refocuses) via the tabs store first.
    const prevActive = tabs.activeId;
    let tabId: string | null = null;
    if (p.type === "tab") {
      tabId = p.tabId;
    } else {
      const path = await dnd.resolvePath();
      if (path) {
        await tabs.open(path);
        tabId = tabs.activeId;
      }
    }
    dnd.end();
    if (!tabId) return;

    chrome.mode = "doc";
    if (z === "left" || z === "right") {
      panes.splitWith(tabId, z, prevActive);
    } else if (panes.isSplit) {
      panes.showInPane(paneIdx, tabId);
      await tabs.focus(tabId);
    } else {
      await tabs.focus(tabId);
    }
  }
</script>

{#if dnd.payload}
  <div
    class="overlay"
    bind:this={hostEl}
    role="presentation"
    ondragover={track}
    ondragleave={leave}
    ondrop={drop}
  >
    {#if zone === "left" || zone === "right"}
      <div class="split-preview {zone}">
        <span class="pill">Split {zone}</span>
      </div>
    {:else if zone === "center"}
      <div
        class="here-preview"
        style="left: {paneRect.left * 100}%; width: {paneRect.width * 100}%;"
      >
        <span class="pill">Open here</span>
      </div>
    {/if}
  </div>
{/if}

<style>
  .overlay {
    position: absolute;
    inset: 0;
    z-index: 150;
  }
  .split-preview {
    position: absolute;
    top: 6px;
    bottom: 6px;
    width: calc(50% - 9px);
    border-radius: 10px;
    background: color-mix(in srgb, var(--color-brand) 14%, transparent);
    border: 1.5px solid color-mix(in srgb, var(--color-brand) 55%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    animation: drop-in 0.14s cubic-bezier(0.2, 0, 0, 1);
    pointer-events: none;
  }
  .split-preview.left { left: 6px; }
  .split-preview.right { right: 6px; }
  .here-preview {
    position: absolute;
    top: 6px;
    bottom: 6px;
    border-radius: 10px;
    box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--color-brand) 55%, transparent);
    background: color-mix(in srgb, var(--color-brand) 6%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    animation: drop-in 0.14s cubic-bezier(0.2, 0, 0, 1);
    pointer-events: none;
  }
  .pill {
    padding: 5px 12px;
    border-radius: 999px;
    background: var(--color-brand);
    color: white;
    font-size: 12px;
    font-weight: 600;
    box-shadow: 0 2px 10px color-mix(in srgb, var(--color-brand) 40%, transparent);
  }
  @keyframes drop-in {
    from { opacity: 0; transform: scale(0.985); }
    to { opacity: 1; transform: scale(1); }
  }
</style>
