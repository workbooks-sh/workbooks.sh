<script lang="ts">
  /**
   * Titlebar — the single, always-36px top chrome, styled as a
   * Chrome-browser tab strip.
   *
   * Layout (left → right):
   *   [78px traffic-light padding]
   *   [⌄ menu]  — overflow/app menu: Search, Bookmarks, Terminal
   *   [tab][tab][tab]…  — stretched Chrome-style document tabs
   *   [+]  — new tab → the Create (home) surface
   *   [spacer]
   *   [⬤ engine]  — compact engine status icon
   *   [Agent]
   *
   * The Search / Bookmarks / Terminal triggers used to be always-visible
   * bar buttons; they now live inside the ⌄ menu (their drawers,
   * features, and keyboard shortcuts are unchanged). The ⌄ menu also
   * anchors the BookmarksPopover (mounted in +page.svelte).
   *
   * Tauri drag: the bar surface is `data-tauri-drag-region` so the user
   * can drag from any non-interactive part. Buttons opt out with
   * `data-tauri-drag-region="false"`. macOS uses `titleBarStyle:
   * "Overlay"` with 78px left padding reserving traffic-light space.
   */
  import {
    X,
    Plus,
    CaretDown as ChevronDown,
    MagnifyingGlass as Search,
    BookmarkSimple as Bookmark,
    ChatCircle as MessageCircle,
    Terminal as TerminalIcon,
    FileText,
    FileCode,
    Hash,
    Cube as Box,
    SidebarSimple,
  } from "phosphor-svelte";
  import { fly, fade } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { terminalDrawer } from "$lib/bridge/terminal.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import type { Tab } from "$lib/tabs/types";
  import { geminiLive } from "$lib/live/gemini.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { wizard } from "$lib/setup/wizard.svelte";
  import ContextMenu from "$lib/components/ContextMenu.svelte";

  // Engine connection state, surfaced (offline-first: the app runs without it).
  const engine = $derived.by(() => {
    const s = sidecar.status.state;
    if (s === "ready") return { cls: "ok", title: "Engine connected — click to manage" };
    if (s === "starting" || s === "restarting")
      return { cls: "pending", title: "Engine starting — click to manage" };
    return { cls: "off", title: "Engine not connected — click to set up" };
  });

  function kindIcon(kind: Tab["kind"]) {
    switch (kind) {
      case "workbook": return Box;
      case "org": return Hash;
      case "code": return FileCode;
      case "text":
      default: return FileText;
    }
  }

  // ── ⌄ overflow / app menu ────────────────────────────────────────
  let menuOpen = $state(false);
  let menuBtnEl: HTMLButtonElement | undefined = $state();
  let menuX = $state(0);
  let menuY = $state(0);

  function toggleMenu() {
    if (menuOpen) {
      menuOpen = false;
      return;
    }
    const r = menuBtnEl?.getBoundingClientRect();
    menuX = r ? r.left : 8;
    menuY = r ? r.bottom + 4 : 40;
    menuOpen = true;
  }

  function menuSearch() {
    menuOpen = false;
    chrome.openSearch();
  }
  function menuBookmarks() {
    menuOpen = false;
    // Anchor the bookmarks popover to the menu button.
    chrome.bookmarksAnchor = menuBtnEl ?? null;
    chrome.bookmarksOpen = true;
  }
  function menuTerminal() {
    menuOpen = false;
    terminalDrawer.show();
  }

  // ── tabs ─────────────────────────────────────────────────────────
  async function focusDoc(id: string) {
    chrome.mode = "doc";
    await tabsStore.focus(id);
  }

  async function closeDoc(id: string, e: MouseEvent) {
    e.stopPropagation();
    await tabsStore.close(id);
    if (tabsStore.tabs.length === 0) chrome.mode = "app";
  }

  // "+" → the Create (home) surface, which is the blank create/home
  // view. The rail's `active` is owned by +page.svelte; route to it via
  // the chrome navigation channel and drop out of doc mode.
  function newTab() {
    chrome.mode = "app";
    chrome.navigateTo("home");
  }
</script>

<div class="titlebar" data-tauri-drag-region role="presentation">
  <button
    type="button"
    class="menu-btn"
    class:menu-active={chrome.sidebarOpen}
    data-tauri-drag-region="false"
    title="Toggle sidebar (⌘B)"
    aria-label="Toggle sidebar"
    aria-pressed={chrome.sidebarOpen}
    onclick={() => chrome.toggleSidebar()}
  >
    <SidebarSimple size={16} weight={chrome.sidebarOpen ? "fill" : "regular"} />
  </button>

  <button
    type="button"
    class="menu-btn"
    data-tauri-drag-region="false"
    title="Menu"
    aria-label="Menu"
    aria-haspopup="menu"
    aria-expanded={menuOpen}
    bind:this={menuBtnEl}
    onclick={toggleMenu}
  >
    <ChevronDown size={15} weight="bold" />
  </button>

  <div class="tabs" role="tablist">
    {#each tabsStore.tabs as tab (tab.id)}
      {@const active = chrome.mode === "doc" && tabsStore.activeId === tab.id}
      {@const Icon = kindIcon(tab.kind)}
      <div
        class="tab"
        class:active
        role="tab"
        aria-selected={active}
        title={tab.path}
        in:fly={{ y: 8, duration: 180, easing: cubicOut }}
        out:fade={{ duration: 90 }}
      >
        <button
          type="button"
          class="tab-body"
          data-tauri-drag-region="false"
          onclick={() => focusDoc(tab.id)}
        >
          <span class="favicon kind-{tab.kind}"><Icon size={13} weight="fill" /></span>
          <span class="title">{tab.title}</span>
          {#if tab.dirty}<span class="dot" aria-label="modified"></span>{/if}
        </button>
        <button
          type="button"
          class="close"
          data-tauri-drag-region="false"
          aria-label="Close tab"
          onclick={(e) => closeDoc(tab.id, e)}
        >
          <X size={12} weight="bold" />
        </button>
      </div>
    {/each}

    <button
      type="button"
      class="new-tab"
      data-tauri-drag-region="false"
      title="New tab"
      aria-label="New tab"
      onclick={newTab}
    >
      <Plus size={15} weight="bold" />
    </button>
  </div>

  <span class="spacer" data-tauri-drag-region></span>

  <button
    type="button"
    class="engine engine-{engine.cls}"
    data-tauri-drag-region="false"
    title={engine.title}
    aria-label={engine.title}
    onclick={() => wizard.open()}
  >
    <span class="engine-dot"></span>
  </button>

  <button
    type="button"
    class="agent-btn"
    class:active={chrome.agentOpen}
    class:live={geminiLive.active}
    data-tauri-drag-region="false"
    title={geminiLive.active
      ? geminiLive.muted
        ? "Agent (live, muted — press space)"
        : "Agent (live)"
      : "Agent (⌘J)"}
    aria-label="Agent (⌘J)"
    aria-pressed={chrome.agentOpen}
    onclick={() => (chrome.agentOpen = !chrome.agentOpen)}
  >
    <MessageCircle size={12} weight="fill" />
    <span>Agent</span>
    {#if geminiLive.active}
      <span class="live-dot" class:muted={geminiLive.muted} aria-hidden="true"></span>
    {/if}
  </button>
</div>

<ContextMenu bind:open={menuOpen} x={menuX} y={menuY}>
  <button class="ctx-item" onclick={menuSearch}>
    <Search size={13} weight="bold" /> Search…
    <span class="ctx-shortcut">⌘K</span>
  </button>
  <button class="ctx-item" onclick={menuBookmarks}>
    <Bookmark size={13} weight="fill" /> Bookmarks
  </button>
  <button class="ctx-item" onclick={menuTerminal}>
    <TerminalIcon size={13} weight="fill" /> Terminal
    <span class="ctx-shortcut">⌃`</span>
  </button>
</ContextMenu>

<style>
  .titlebar {
    position: sticky;
    top: 0;
    z-index: 200;
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

  /* ⌄ overflow / app menu trigger */
  .menu-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    align-self: center;
    height: 26px;
    width: 28px;
    border-radius: 6px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.1s, color 0.1s;
  }
  .menu-btn:hover,
  .menu-btn[aria-expanded="true"] {
    background: var(--color-page);
    color: var(--color-fg);
  }

  .ctx-shortcut {
    margin-left: auto;
    color: var(--color-fg-subtle);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  /* ── tab strip ────────────────────────────────────────────────── */
  .tabs {
    display: flex;
    flex-direction: row;
    align-items: flex-end;
    gap: 2px;
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
  }
  .tab {
    position: relative;
    display: flex;
    align-items: center;
    height: 28px;
    align-self: flex-end;
    border: 1px solid var(--color-border);
    border-bottom: none;
    border-radius: 8px 8px 0 0;
    background: transparent;
    color: var(--color-fg-muted);
    /* Chrome-style: every tab flexes to share the strip width, down to a
     * floor; titles ellipsize as they get squeezed. */
    flex: 1 1 0;
    min-width: 44px;
    max-width: 240px;
    transition: background 0.1s, color 0.1s;
  }
  .tab:hover { background: var(--color-page); color: var(--color-fg); }
  .tab.active {
    background: var(--color-page);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
    margin-bottom: -1px;
    z-index: 1;
  }
  .tab-body {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    background: transparent;
    border: 0;
    padding: 0 0.3rem 0 0.55rem;
    cursor: pointer;
    color: inherit;
    font-size: 12px;
    font-family: inherit;
    min-width: 0;
    flex: 1 1 auto;
    text-align: left;
    height: 100%;
  }
  .tab.active .tab-body { font-weight: 500; }
  .title {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    flex: 1 1 auto;
  }
  .favicon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    opacity: 0.7;
  }
  .kind-workbook { color: #5b8cff; opacity: 0.95; }
  .kind-org { color: #10b981; opacity: 0.95; }
  .kind-code { color: #a855f7; opacity: 0.95; }
  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-fg-muted);
    display: inline-block;
    flex-shrink: 0;
  }
  .close {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    padding: 0 0.4rem;
    height: 100%;
    border-radius: 0 8px 0 0;
    flex-shrink: 0;
    opacity: 0;
    transition: opacity 0.1s, background 0.1s, color 0.1s;
  }
  .tab:hover .close,
  .tab.active .close { opacity: 0.7; }
  .close:hover {
    opacity: 1;
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  /* "+" new-tab button, sits at the right end of the strip */
  .new-tab {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    align-self: center;
    height: 26px;
    width: 28px;
    border-radius: 6px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    flex-shrink: 0;
    margin-left: 2px;
    transition: background 0.1s, color 0.1s;
  }
  .new-tab:hover { background: var(--color-page); color: var(--color-fg); }

  .spacer { flex: 0 0 0.25rem; }

  /* Compact engine status icon — a colored dot reflecting engine state.
   * Click opens the engine setup/manage wizard. */
  .engine {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    align-self: center;
    height: 24px;
    width: 24px;
    border: 1px solid transparent;
    border-radius: 6px;
    background: transparent;
    flex-shrink: 0;
    cursor: pointer;
    user-select: none;
  }
  .engine:hover { border-color: var(--color-border); background: var(--color-page); }
  .engine-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--color-fg-subtle);
  }
  .engine-ok .engine-dot { background: var(--color-ok); }
  .engine-pending .engine-dot {
    background: var(--color-warn);
    animation: engine-pulse 1.4s ease-in-out infinite;
  }
  .engine-off .engine-dot { background: var(--color-fg-subtle); }
  @keyframes engine-pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.35; }
  }
  @media (prefers-reduced-motion: reduce) {
    .engine-pending .engine-dot { animation: none; }
  }

  /* Agent button — pinned to the right edge of the titlebar. */
  .agent-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    align-self: center;
    height: 24px;
    padding: 0 0.7rem;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    background: var(--color-page);
    color: var(--color-fg-muted);
    font-size: 12px;
    font-family: inherit;
    font-weight: 500;
    cursor: pointer;
    flex-shrink: 0;
  }
  .agent-btn:hover { color: var(--color-fg); }
  .agent-btn.active {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: var(--color-fg);
  }

  /* Live-session indicator on the agent button: small pulsing dot.
   * Mutes to a static dim dot when geminiLive.muted is true so the
   * user can tell at a glance whether the mic is hot. */
  .live-dot {
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #34d399; /* emerald */
    box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.7);
    animation: live-dot-pulse 1.6s ease-out infinite;
  }
  .live-dot.muted {
    background: #fbbf24; /* amber when muted */
    animation: none;
  }
  @keyframes live-dot-pulse {
    0%   { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.7); }
    70%  { box-shadow: 0 0 0 6px rgba(52, 211, 153, 0); }
    100% { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0); }
  }
  @media (prefers-reduced-motion: reduce) {
    .live-dot { animation: none; }
  }
</style>
