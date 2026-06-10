<script lang="ts">
  /**
   * DocViewer — renders the doc area: the active tab (implicit single
   * pane), or the split layout from the panes store (epic wb-5fl).
   *
   * The tab strip lives in the Titlebar. Per-pane rendering dispatches
   * on tab.kind; `{#key tabId}` remounts on swap (no keep-alive).
   * Dividers between panes drag to resize (width fractions in the
   * panes store, 15% floor).
   */
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import { panes } from "$lib/viewer/panes.svelte";
  import type { Tab } from "$lib/tabs/types";
  import WorkbookView from "./WorkbookView.svelte";
  import CodeView from "./CodeView.svelte";
  import TextView from "./TextView.svelte";
  import OrgEditor from "$lib/org-renderer/OrgEditor.svelte";

  // Closing a tab anywhere must release its pane.
  $effect(() => {
    panes.reconcile(new Set(tabsStore.tabs.map((t) => t.id)));
  });

  function tabById(id: string): Tab | null {
    return tabsStore.tabs.find((t) => t.id === id) ?? null;
  }

  // ── divider drag ────────────────────────────────────────────────
  let docEl: HTMLDivElement | undefined = $state();
  let dragDivider = $state<number | null>(null);

  function dividerDown(i: number, e: PointerEvent) {
    dragDivider = i;
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }
  function dividerMove(e: PointerEvent) {
    if (dragDivider === null || !docEl) return;
    panes.resize(dragDivider, e.movementX / docEl.clientWidth);
  }
  function dividerUp() {
    dragDivider = null;
  }
</script>

{#snippet docBody(tab: Tab)}
  {#key tab.id}
    {#if tab.kind === "workbook"}
      <WorkbookView path={tab.path} />
    {:else if tab.kind === "org"}
      <OrgEditor path={tab.path} tabId={tab.id} />
    {:else if tab.kind === "code"}
      <CodeView path={tab.path} />
    {:else}
      <TextView path={tab.path} />
    {/if}
  {/key}
{/snippet}

<div class="doc" bind:this={docEl}>
  {#if panes.isSplit}
    {#each panes.panes as pane, i (pane.id)}
      {@const tab = tabById(pane.tabId)}
      <section
        class="pane"
        class:focused={panes.focused === i}
        style="flex: {panes.sizes[i] ?? 1} 1 0;"
        onpointerdown={() => (panes.focused = i)}
      >
        {#if tab}
          {@render docBody(tab)}
        {:else}
          <div class="empty"><p>Closed.</p></div>
        {/if}
      </section>
      {#if i < panes.panes.length - 1}
        <div
          class="divider"
          class:dragging={dragDivider === i}
          role="separator"
          aria-orientation="vertical"
          onpointerdown={(e) => dividerDown(i, e)}
          onpointermove={dividerMove}
          onpointerup={dividerUp}
        ></div>
      {/if}
    {/each}
  {:else if tabsStore.active}
    <section class="pane" style="flex: 1 1 0;">
      {@render docBody(tabsStore.active)}
    </section>
  {:else}
    <div class="empty">
      <p>No document selected.</p>
    </div>
  {/if}
</div>

<style>
  .doc {
    flex: 1 1 auto;
    min-height: 0;
    min-width: 0;
    display: flex;
    flex-direction: row;
    background: var(--color-page);
    overflow: hidden;
  }
  .pane {
    display: flex;
    flex-direction: column;
    min-width: 0;
    min-height: 0;
    overflow: hidden;
    border-radius: 0;
    box-shadow: inset 0 0 0 1px transparent;
    transition: box-shadow 0.12s;
  }
  .pane.focused {
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--color-brand) 35%, transparent);
  }
  .divider {
    flex: 0 0 5px;
    cursor: col-resize;
    background: var(--color-border);
    background-clip: content-box;
    padding: 0 2px;
    transition: background-color 0.12s;
    touch-action: none;
  }
  .divider:hover,
  .divider.dragging {
    background-color: var(--color-brand);
    background-clip: content-box;
  }
  .empty {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--color-fg-muted);
    font-size: 0.9rem;
  }
</style>
