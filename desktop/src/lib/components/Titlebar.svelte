<script lang="ts">
  /**
   * Titlebar — the single, always-36px top chrome.
   *
   * Layout (left → right):
   *   [78px traffic-light padding] [Search] [Bookmarks] [Terminal]
   *   [App pill] [doc tab]… [spacer] [Agent button]
   *
   * The App pill represents the routed main sections (the active rail
   * tab); each remaining tab is a browser-style document tab from the
   * tabs store. Clicking the pill returns to app mode; clicking a tab
   * enters doc mode. The whole bar is a Tauri drag region except the
   * buttons, which opt out. macOS reserves 78px for traffic lights.
   */
  import { X, AppWindow, Search, Bookmark, MessageCircle, Terminal as TerminalIcon, FolderOpen } from "@lucide/svelte";
  import { chrome } from "$lib/chrome.svelte";
  import { tabs } from "$lib/tabs.svelte";
  import { pickFilePath } from "$lib/files";
  import type { Tab } from "$lib/bindings";

  function kindGlyph(kind: Tab["kind"]): string {
    switch (kind) {
      case "workbook": return "◆";
      case "org": return "◉";
      case "code": return "{ }";
      default: return "—";
    }
  }

  const searchOpen = $derived(chrome.leftPanel === "search");

  let bookmarkBtnEl = $state<HTMLButtonElement>();
  function toggleBookmarks() {
    chrome.bookmarksAnchor = bookmarkBtnEl ?? null;
    chrome.bookmarksOpen = !chrome.bookmarksOpen;
  }

  async function openFile() {
    const path = await pickFilePath();
    if (!path) return;
    chrome.mode = "doc";
    await tabs.open(path);
  }

  async function focusDoc(id: string) {
    chrome.mode = "doc";
    await tabs.focus(id);
  }
  async function closeDoc(id: string, e: MouseEvent) {
    e.stopPropagation();
    await tabs.close(id);
    if (tabs.tabs.length === 0) chrome.mode = "app";
  }
</script>

<div class="titlebar" data-tauri-drag-region role="presentation">
  <div class="left-tools">
    <button type="button" class="icon-btn" data-tauri-drag-region="false"
      title="Search (⌘K)" aria-label="Search" aria-pressed={searchOpen}
      onclick={() => chrome.toggleSearch()}>
      <Search size={14} strokeWidth={1.8} />
    </button>
    <button type="button" class="icon-btn" data-tauri-drag-region="false"
      title="Bookmarks (⌘B)" aria-label="Bookmarks" aria-pressed={chrome.bookmarksOpen}
      bind:this={bookmarkBtnEl} onclick={toggleBookmarks}>
      <Bookmark size={14} strokeWidth={1.8} />
    </button>
    <button type="button" class="icon-btn" data-tauri-drag-region="false"
      title="Terminal (⌃`)" aria-label="Toggle terminal" aria-pressed={chrome.terminalOpen}
      onclick={() => (chrome.terminalOpen = !chrome.terminalOpen)}>
      <TerminalIcon size={14} strokeWidth={1.8} />
    </button>
    <button type="button" class="icon-btn" data-tauri-drag-region="false"
      title="Open file" aria-label="Open file" onclick={() => void openFile()}>
      <FolderOpen size={14} strokeWidth={1.8} />
    </button>
  </div>

  <button type="button" class="pill app-pill" class:active={chrome.mode === "app"}
    data-tauri-drag-region="false" title="App ({chrome.section})"
    aria-pressed={chrome.mode === "app"} onclick={() => (chrome.mode = "app")}>
    <AppWindow size={12} strokeWidth={2} />
    <span class="pill-label">{chrome.section || "App"}</span>
  </button>

  <div class="tabs" role="tablist">
    {#each tabs.tabs as tab (tab.id)}
      {@const active = chrome.mode === "doc" && tabs.activeId === tab.id}
      <div class="tab" class:active role="tab" aria-selected={active} title={tab.path}>
        <button type="button" class="tab-body" data-tauri-drag-region="false" onclick={() => focusDoc(tab.id)}>
          <span class="kind kind-{tab.kind}">{kindGlyph(tab.kind)}</span>
          <span class="title">{tab.title}</span>
          {#if tab.dirty}<span class="dot" aria-label="modified"></span>{/if}
        </button>
        <button type="button" class="close" data-tauri-drag-region="false"
          aria-label="Close tab" onclick={(e) => closeDoc(tab.id, e)}>
          <X size={11} strokeWidth={2} />
        </button>
      </div>
    {/each}
  </div>

  <span class="spacer" data-tauri-drag-region></span>

  <button type="button" class="agent-btn" class:active={chrome.agentOpen}
    data-tauri-drag-region="false" title="Agent (⌘J)" aria-label="Agent"
    aria-pressed={chrome.agentOpen} onclick={() => (chrome.agentOpen = !chrome.agentOpen)}>
    <MessageCircle size={12} strokeWidth={2} />
    <span>Agent</span>
  </button>
</div>

<style>
  .titlebar {
    display: flex;
    align-items: stretch;
    gap: 0.4rem;
    height: 36px;
    flex: 0 0 36px;
    padding: 0 0.5rem 0 78px;
    background: var(--color-surface-soft);
    border-bottom: 1px solid var(--color-border);
    user-select: none;
    -webkit-user-select: none;
  }
  .left-tools { display: flex; align-items: center; gap: 2px; flex-shrink: 0; }
  .icon-btn {
    display: inline-flex; align-items: center; justify-content: center;
    height: 24px; width: 24px; border-radius: 6px;
    background: transparent; border: 0; color: var(--color-fg-muted);
    cursor: pointer; flex-shrink: 0; transition: background 0.1s, color 0.1s;
  }
  .icon-btn:hover, .icon-btn[aria-pressed="true"] {
    background: var(--color-page); color: var(--color-fg);
  }
  .app-pill {
    display: inline-flex; align-items: center; gap: 0.4rem; align-self: center;
    height: 24px; padding: 0 0.65rem; border: 1px solid var(--color-border);
    border-radius: 6px; background: var(--color-page); color: var(--color-fg-muted);
    font-size: 12px; font-family: inherit; cursor: pointer; flex-shrink: 0;
  }
  .app-pill:hover { color: var(--color-fg); }
  .app-pill.active {
    background: var(--color-surface); color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .pill-label { font-weight: 500; letter-spacing: -0.005em; }
  .tabs {
    display: flex; align-items: flex-end; gap: 2px; min-width: 0;
    overflow-x: auto; overflow-y: hidden; scrollbar-width: thin;
  }
  .tab {
    position: relative; display: flex; align-items: center; height: 28px;
    border: 1px solid var(--color-border); border-bottom: none;
    border-radius: 7px 7px 0 0; background: transparent;
    color: var(--color-fg-muted); min-width: 0; max-width: 200px;
    transition: background 0.1s, color 0.1s;
  }
  .tab:hover { background: var(--color-page); color: var(--color-fg); }
  .tab.active {
    background: var(--color-page); color: var(--color-fg);
    border-color: var(--color-border-strong); margin-bottom: -1px; z-index: 1;
  }
  .tab-body {
    display: flex; align-items: center; gap: 0.4rem; background: transparent;
    border: 0; padding: 0 0.45rem 0 0.6rem; cursor: pointer; color: inherit;
    font-size: 12px; font-family: inherit; min-width: 0; flex: 1 1 auto;
    text-align: left; height: 100%;
  }
  .tab.active .tab-body { font-weight: 500; }
  .title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
  .kind {
    display: inline-flex; align-items: center; justify-content: center; width: 12px;
    font-size: 10px; opacity: 0.55; font-family: ui-monospace, SFMono-Regular, monospace;
    flex-shrink: 0;
  }
  .kind-workbook { color: #5b8cff; opacity: 0.9; }
  .kind-org { color: var(--color-ok); opacity: 0.9; }
  .kind-code { color: #a855f7; opacity: 0.9; }
  .dot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--color-fg-muted); display: inline-block; flex-shrink: 0;
  }
  .close {
    display: inline-flex; align-items: center; justify-content: center;
    background: transparent; border: 0; color: var(--color-fg-muted); cursor: pointer;
    padding: 0 0.45rem; height: 100%; border-radius: 0 7px 0 0; opacity: 0;
    transition: opacity 0.1s, background 0.1s, color 0.1s;
  }
  .tab:hover .close, .tab.active .close { opacity: 0.7; }
  .close:hover { opacity: 1; background: var(--color-surface-soft); color: var(--color-fg); }
  .spacer { flex: 1 1 auto; }
  .agent-btn {
    display: inline-flex; align-items: center; gap: 0.4rem; align-self: center;
    height: 24px; padding: 0 0.7rem; border: 1px solid var(--color-border);
    border-radius: 6px; background: var(--color-page); color: var(--color-fg-muted);
    font-size: 12px; font-family: inherit; font-weight: 500; cursor: pointer; flex-shrink: 0;
  }
  .agent-btn:hover { color: var(--color-fg); }
  .agent-btn.active {
    background: var(--color-fg); color: var(--color-page); border-color: var(--color-fg);
  }
</style>
