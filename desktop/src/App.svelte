<script lang="ts">
  /**
   * App shell — the persistent chrome around the routed views.
   *
   * Layout (top → bottom, left → right):
   *   ┌─────────────────────────────────────────────┐
   *   │ rail │ left panel │ titlebar           agent │
   *   │      │ (files /   │ ─────────────────  panel │
   *   │      │  search)   │ main view (app/doc)│      │
   *   ├─────────────────────────────────────────────┤
   *   │ terminal drawer (bottom, toggle ⌃`)          │
   *   └─────────────────────────────────────────────┘
   *
   * The router renders the active *app* section into the main view;
   * `chrome` owns the surrounding shell (mode, panels, agent/terminal
   * drawers). When chrome.mode === "doc" the main view shows the focused
   * document tab instead of the routed section — the DocViewer surface is
   * its own rebuild, so a labelled placeholder stands in for now.
   *
   * Keyboard: ⌘K search, ⌘J agent, ⌘B bookmarks, ⌃` terminal,
   * ⌘1..⌘9 open bookmark slots. Cross-component nav requests
   * (chrome.requestedSection) are consumed here and pushed to the router.
   */
  import { onMount } from "svelte";
  import { RouterContext, RouterView } from "@dvcol/svelte-simple-router/components";
  import type { IRouter } from "@dvcol/svelte-simple-router/models";
  import { routerOptions } from "./router";
  import AppRail from "$lib/components/AppRail.svelte";
  import Titlebar from "$lib/components/Titlebar.svelte";
  import PackageDrawer from "$lib/components/PackageDrawer.svelte";
  import SearchDrawer from "$lib/components/SearchDrawer.svelte";
  import AgentPanel from "$lib/components/AgentPanel.svelte";
  import TerminalDrawer from "$lib/components/TerminalDrawer.svelte";
  import BookmarksPopover from "$lib/components/BookmarksPopover.svelte";
  import DocView from "$lib/views/DocView.svelte";
  import { auth } from "$lib/auth.svelte";
  import { chrome } from "$lib/chrome.svelte";
  import { tabs } from "$lib/tabs.svelte";
  import { workspace } from "$lib/workspace.svelte";
  import { commands } from "$lib/bindings";

  onMount(() => {
    void auth.init();
    void tabs.init();
    // Explorable by default: load the persisted root and show the file tree.
    void workspace.init();
    chrome.openFiles();
  });

  function onKey(e: KeyboardEvent) {
    const meta = e.metaKey || e.ctrlKey;
    if (meta && e.key.toLowerCase() === "k") { e.preventDefault(); chrome.toggleSearch(); return; }
    if (meta && e.key.toLowerCase() === "j") { e.preventDefault(); chrome.agentOpen = !chrome.agentOpen; return; }
    if (meta && e.key.toLowerCase() === "b") { e.preventDefault(); chrome.bookmarksOpen = !chrome.bookmarksOpen; return; }
    if (e.ctrlKey && e.key === "`") { e.preventDefault(); chrome.terminalOpen = !chrome.terminalOpen; return; }
    if (meta && /^[1-9]$/.test(e.key)) { e.preventDefault(); void openBookmarkSlot(Number(e.key)); }
  }

  async function openBookmarkSlot(slot: number) {
    const list = await commands.bookmarksList();
    const bm = list[slot - 1];
    if (!bm) return;
    chrome.mode = "doc";
    await tabs.open(bm.path);
  }
</script>

<svelte:window onkeydown={onKey} />

<RouterContext options={routerOptions}>
  {#snippet children(router: IRouter)}
    <div class="app">
      <Titlebar />

      <div class="body">
        <AppRail {router} />

        {#if chrome.leftPanel === "files"}
          <PackageDrawer />
        {:else if chrome.leftPanel === "search"}
          <SearchDrawer />
        {/if}

        <main class="center">
          <div class="view">
            {#if chrome.mode === "doc" && tabs.active}
              <DocView />
            {:else}
              <RouterView {router} />
            {/if}
          </div>
        </main>

        {#if chrome.agentOpen}
          <AgentPanel />
        {/if}
      </div>

      {#if chrome.terminalOpen}
        <TerminalDrawer />
      {/if}
    </div>

    {#if chrome.bookmarksOpen}
      <BookmarksPopover />
    {/if}
  {/snippet}
</RouterContext>

<style>
  .app {
    display: flex;
    flex-direction: column;
    height: 100vh;
    width: 100vw;
    overflow: hidden;
    background: var(--color-page);
  }
  .body {
    flex: 1 1 auto;
    display: flex;
    min-height: 0;
  }
  .center {
    flex: 1 1 auto;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .view {
    flex: 1 1 auto;
    min-height: 0;
    overflow: auto;
  }
</style>
