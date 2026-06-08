<script lang="ts">
  /**
   * DocViewer — renders the active document tab inside the main area.
   *
   * The tab strip itself lives in the Titlebar now (no inner tab bar).
   * This component only dispatches on tab.kind to the per-format
   * renderer. The `{#key tab.id}` block remounts when the active tab
   * switches; tabs in the background are unmounted (no keep-alive).
   */
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import WorkbookView from "./WorkbookView.svelte";
  import CodeView from "./CodeView.svelte";
  import TextView from "./TextView.svelte";
  import OrgEditor from "$lib/org-renderer/OrgEditor.svelte";
</script>

<div class="doc">
  {#if tabsStore.active}
    {@const tab = tabsStore.active}
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
    flex-direction: column;
    background: var(--color-page);
    overflow: hidden;
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
