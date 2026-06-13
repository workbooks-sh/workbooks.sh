<script lang="ts">
  /**
   * PackageTreeDrawer — left-side pop-out panel for the active Package.
   * Hosts a switcher (wb-i38o.38) that flips between two layouts:
   *
   *   • Grid — iOS-springboard of workbooks (PackageGridView)
   *   • Tree — full file tree (FileTreePanel, the legacy view)
   *
   * The default layout is persisted on the Package (`layout` field);
   * per-session toggling here doesn't rewrite the default, it just
   * overrides what's rendered.
   *
   * Replaces the old RightRail. Triggered by clicking the active
   * Package's avatar in the AppRail (parent drives `open`).
   * See docs/canonical-model.md for the User → Workspace → Package
   * hierarchy.
   */
  import { SquaresFour as LayoutGrid, TreeView as ListTree } from "phosphor-svelte";
  import FileTreePanel from "./FileTreePanel.svelte";
  import PackageGridView from "./PackageGridView.svelte";
  import { packageStore, type Layout } from "$lib/bridge/package.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";

  // Resize by dragging the right edge (it's a left-side panel).
  let dragging = $state(false);
  function startResize(e: PointerEvent) {
    dragging = true;
    const startX = e.clientX;
    const startW = chrome.filesWidth;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    const move = (ev: PointerEvent) => {
      if (dragging) chrome.setFilesWidth(startW + (ev.clientX - startX));
    };
    const up = () => {
      dragging = false;
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }

  // Per-session override; null = use the Package's stored default.
  let override = $state<Layout | null>(null);

  const effective = $derived<Layout>(
    override ?? packageStore.active?.layout ?? "grid",
  );

  function setLayout(next: Layout) {
    override = next;
    const active = packageStore.active;
    if (active && active.layout !== next) {
      void packageStore.setLayout(active.name, next);
    }
  }
</script>

<aside class="drawer" class:dragging aria-label="Package files" style="width: {chrome.filesWidth}px">
  <button type="button" class="resize" class:dragging aria-label="Resize files" onpointerdown={startResize}></button>
  <header class="hdr">
    <span class="label">{packageStore.active?.name ?? "Package"}</span>
    <div class="switcher" role="tablist" aria-label="Layout">
      <button
        type="button"
        class="seg"
        class:active={effective === "grid"}
        role="tab"
        aria-selected={effective === "grid"}
        title="Grid"
        aria-label="Grid layout"
        onclick={() => setLayout("grid")}
      >
        <LayoutGrid weight="fill" size={12} aria-hidden="true" />
      </button>
      <button
        type="button"
        class="seg"
        class:active={effective === "tree"}
        role="tab"
        aria-selected={effective === "tree"}
        title="Tree"
        aria-label="Tree layout"
        onclick={() => setLayout("tree")}
      >
        <ListTree weight="fill" size={12} aria-hidden="true" />
      </button>
    </div>
  </header>

  {#if effective === "grid"}
    <PackageGridView />
  {:else}
    <FileTreePanel />
  {/if}
</aside>

<style>
  .drawer {
    position: relative;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    background: var(--color-surface);
    border-right: 1px solid var(--color-border);
  }
  .drawer.dragging { user-select: none; }
  /* Resize handle straddling the right edge. */
  .resize {
    position: absolute;
    top: 0;
    bottom: 0;
    right: -5px;
    width: 10px;
    padding: 0;
    border: 0;
    background: transparent;
    cursor: col-resize;
    z-index: 2;
  }
  .resize::after {
    content: "";
    position: absolute;
    inset: 8px 4px;
    border-radius: 2px;
    background: transparent;
    transition: background 0.15s;
  }
  .resize:hover::after,
  .resize.dragging::after { background: var(--color-border-strong); }
  .hdr {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 6px 8px 6px 10px;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface);
  }
  .label {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 500;
    color: var(--color-fg-muted);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .switcher {
    display: flex;
    gap: 0;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    overflow: hidden;
    background: var(--color-surface-soft);
  }
  .seg {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    cursor: pointer;
  }
  .seg:hover { color: var(--color-fg); }
  .seg.active {
    background: var(--color-surface);
    color: var(--color-fg);
  }
</style>
