<script lang="ts">
  /**
   * Titlebar — the single, always-42px top chrome, styled as a
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
  import { invoke } from "@tauri-apps/api/core";
  import { terminalDrawer } from "$lib/bridge/terminal.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { dnd } from "$lib/ui/dnd.svelte";
  import { docIcons } from "$lib/ui/docIcon.svelte";
  import IconResolver from "$lib/ui/Icon.svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import { panes } from "$lib/viewer/panes.svelte";
  import { bookmarks } from "$lib/bridge/bookmarks.svelte";
  import ShareDrawer from "$lib/share/ShareDrawer.svelte";
  import WorkbookProvenance from "$lib/network/components/WorkbookProvenance.svelte";
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

  // ── tab context menu (wb-5fl.8) — Share / provenance / splits live
  // here now instead of as page chrome on every workbook. ───────────
  let tabMenuOpen = $state(false);
  let tabMenuX = $state(0);
  let tabMenuY = $state(0);
  let tabMenuTarget = $state<Tab | null>(null);

  function onTabContext(tab: Tab, e: MouseEvent) {
    e.preventDefault();
    tabMenuTarget = tab;
    tabMenuX = e.clientX;
    tabMenuY = e.clientY;
    tabMenuOpen = true;
  }

  /** Base for a split started from the menu: the visible doc, or any
   *  other tab when the target IS the visible doc. */
  function splitBaseFor(id: string): string | null {
    const cur = tabsStore.activeId;
    if (cur && cur !== id) return cur;
    return tabsStore.tabs.find((t) => t.id !== id)?.id ?? null;
  }
  function menuSplit(side: "left" | "right") {
    const t = tabMenuTarget;
    tabMenuOpen = false;
    if (!t) return;
    panes.splitWith(t.id, side, splitBaseFor(t.id));
    chrome.mode = "doc";
  }
  async function menuBookmarkTab() {
    const t = tabMenuTarget;
    tabMenuOpen = false;
    if (!t || bookmarks.bookmarks.some((b) => b.path === t.path)) return;
    try {
      await bookmarks.create(t.title, t.path);
    } catch (e) {
      console.warn("[titlebar] bookmark failed", e);
    }
  }
  function menuCopyPath() {
    const t = tabMenuTarget;
    tabMenuOpen = false;
    if (t) void navigator.clipboard.writeText(t.path);
  }
  async function menuCloseOthers() {
    const t = tabMenuTarget;
    tabMenuOpen = false;
    if (!t) return;
    for (const x of [...tabsStore.tabs]) {
      if (x.id !== t.id) await tabsStore.close(x.id);
    }
  }
  function menuClose() {
    const t = tabMenuTarget;
    tabMenuOpen = false;
    if (t) void tabsStore.close(t.id);
  }

  // Share drawer + provenance popover, opened from the tab menu.
  let sharePath = $state<string | null>(null);
  function menuShare() {
    const t = tabMenuTarget;
    tabMenuOpen = false;
    if (t) sharePath = t.path;
  }
  let provTitle = $state<string | null>(null);
  let provHtml = $state<string | null>(null);
  let provLoading = $state(false);
  async function menuProvenance() {
    const t = tabMenuTarget;
    tabMenuOpen = false;
    if (!t) return;
    provTitle = t.title;
    provHtml = null;
    provLoading = true;
    try {
      const b64 = await invoke<string>("read_file_bytes_base64", { path: t.path });
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      provHtml = new TextDecoder("utf-8").decode(bytes);
    } catch (e) {
      console.warn("[titlebar] provenance read failed", e);
      provTitle = null;
    } finally {
      provLoading = false;
    }
  }
  function closeProv() {
    provTitle = null;
    provHtml = null;
  }

  // ── combined tab (wb-5fl.10): a split shows as ONE pill in the
  // strip — segments per pane, one close for the whole split. ───────
  const splitIds = $derived(
    panes.isSplit ? panes.panes.map((p) => p.tabId) : [],
  );
  const stripTabs = $derived(
    tabsStore.tabs.filter(
      (t) => !splitIds.includes(t.id) || t.id === splitIds[0],
    ),
  );
  function tabById(id: string): Tab | null {
    return tabsStore.tabs.find((t) => t.id === id) ?? null;
  }
  async function focusSegment(idx: number, id: string) {
    panes.focused = idx;
    chrome.mode = "doc";
    await tabsStore.focus(id);
  }
  async function closeSplit() {
    const ids = [...splitIds];
    for (const id of ids) await tabsStore.close(id);
  }

  // Tab-onto-tab merge: drop one tab on another → split (the combined
  // pill animates in as both tabs leave the strip).
  let mergeHotId = $state<string | null>(null);
  function tabDragOver(tab: Tab, e: DragEvent) {
    const p = dnd.payload;
    if (p?.type !== "tab" || p.tabId === tab.id) return;
    e.preventDefault();
    e.stopPropagation();
    mergeHotId = tab.id;
  }
  function tabDrop(tab: Tab, e: DragEvent) {
    const p = dnd.payload;
    mergeHotId = null;
    if (p?.type !== "tab" || p.tabId === tab.id) return;
    e.preventDefault();
    e.stopPropagation();
    panes.splitWith(p.tabId, "right", tab.id);
    chrome.mode = "doc";
    dnd.end();
  }

  // ── strip as drop target: drag a workbook/app here → new tab ──────
  let stripHot = $state(false);
  function stripOver(e: DragEvent) {
    const p = dnd.payload;
    if (!p || p.type === "tab") return;
    e.preventDefault();
    stripHot = true;
  }
  async function stripDrop(e: DragEvent) {
    const p = dnd.payload;
    stripHot = false;
    if (!p || p.type === "tab") return;
    e.preventDefault();
    const path = await dnd.resolvePath();
    dnd.end();
    if (!path) return;
    await tabsStore.open(path);
    chrome.mode = "doc";
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

  <div
    class="tabs"
    class:drop-hot={stripHot}
    role="tablist"
    ondragover={stripOver}
    ondragleave={() => (stripHot = false)}
    ondrop={stripDrop}
  >
    {#each stripTabs as tab (tab.id)}
      {#if splitIds[0] === tab.id}
        <!-- combined tab — one pill for the whole split -->
        <div
          class="tab combined"
          class:active={chrome.mode === "doc"}
          class:merge-hot={mergeHotId === tab.id}
          role="tab"
          aria-selected={chrome.mode === "doc"}
          ondragover={(e) => tabDragOver(tab, e)}
          ondragleave={() => (mergeHotId = null)}
          ondrop={(e) => tabDrop(tab, e)}
          in:fly={{ y: 8, duration: 200, easing: cubicOut }}
          out:fade={{ duration: 90 }}
        >
          {#each splitIds as segId, i (segId)}
            {@const seg = tabById(segId)}
            {#if seg}
              {@const SegIcon = kindIcon(seg.kind)}
              {@const segIdentity = docIcons.iconFor(seg.path)}
              {#if i > 0}<span class="seg-divider" aria-hidden="true"></span>{/if}
              <button
                type="button"
                class="tab-body segment"
                class:seg-focused={panes.focused === i}
                data-tauri-drag-region="false"
                title={seg.path}
                oncontextmenu={(e) => onTabContext(seg, e)}
                onclick={() => focusSegment(i, segId)}
              >
                <span class="favicon kind-{seg.kind}">
                  {#if segIdentity}
                    <IconResolver value={segIdentity} name={seg.title} size={13} />
                  {:else}
                    <SegIcon size={13} weight="fill" />
                  {/if}
                </span>
                <span class="title">{seg.title}</span>
              </button>
            {/if}
          {/each}
          <button
            type="button"
            class="close"
            data-tauri-drag-region="false"
            aria-label="Close split"
            onclick={() => void closeSplit()}
          >
            <X size={12} weight="bold" />
          </button>
        </div>
      {:else}
        {@const active = chrome.mode === "doc" && tabsStore.activeId === tab.id && !panes.isSplit}
        {@const Icon = kindIcon(tab.kind)}
        {@const identity = docIcons.iconFor(tab.path)}
        <div
          class="tab"
          class:active
          class:merge-hot={mergeHotId === tab.id}
          role="tab"
          aria-selected={active}
          title={tab.path}
          draggable="true"
          ondragstart={(e) =>
            dnd.start(
              { type: "tab", tabId: tab.id, path: tab.path, title: tab.title },
              e,
            )}
          ondragend={() => {
            dnd.end();
            mergeHotId = null;
          }}
          ondragover={(e) => tabDragOver(tab, e)}
          ondragleave={() => (mergeHotId = null)}
          ondrop={(e) => tabDrop(tab, e)}
          oncontextmenu={(e) => onTabContext(tab, e)}
          in:fly={{ y: 8, duration: 180, easing: cubicOut }}
          out:fade={{ duration: 90 }}
        >
          <button
            type="button"
            class="tab-body"
            data-tauri-drag-region="false"
            onclick={() => focusDoc(tab.id)}
          >
            <span class="favicon kind-{tab.kind}">
              {#if identity}
                <IconResolver value={identity} name={tab.title} size={13} />
              {:else}
                <Icon size={13} weight="fill" />
              {/if}
            </span>
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
      {/if}
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

<ContextMenu bind:open={tabMenuOpen} x={tabMenuX} y={tabMenuY}>
  {#if tabMenuTarget?.kind === "workbook"}
    <button class="ctx-item" onclick={menuShare}>Share…</button>
    <button class="ctx-item" onclick={menuProvenance}>
      {provLoading ? "Verifying…" : "Provenance…"}
    </button>
    <div class="ctx-sep"></div>
  {/if}
  <button class="ctx-item" onclick={() => menuSplit("left")}>Split left</button>
  <button class="ctx-item" onclick={() => menuSplit("right")}>Split right</button>
  <button
    class="ctx-item"
    onclick={menuBookmarkTab}
    disabled={!!tabMenuTarget &&
      bookmarks.bookmarks.some((b) => b.path === tabMenuTarget?.path)}
  >
    Bookmark
  </button>
  <button class="ctx-item" onclick={menuCopyPath}>Copy path</button>
  <div class="ctx-sep"></div>
  <button class="ctx-item" onclick={menuClose}>Close</button>
  <button
    class="ctx-item"
    onclick={menuCloseOthers}
    disabled={tabsStore.tabs.length < 2}
  >
    Close others
  </button>
</ContextMenu>

{#if sharePath}
  <ShareDrawer path={sharePath} onclose={() => (sharePath = null)} />
{/if}

{#if provTitle && provHtml}
  <div class="prov-scrim" role="presentation" onclick={closeProv}>
    <div class="prov-card" role="dialog" aria-label="Provenance" onclick={(e) => e.stopPropagation()}>
      <div class="prov-head">
        <span class="prov-title">{provTitle}</span>
        <button type="button" class="close" aria-label="Close" onclick={closeProv}>
          <X size={13} weight="bold" />
        </button>
      </div>
      <WorkbookProvenance html={provHtml} showLineageToggle={true} />
    </div>
  </div>
{/if}

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
    height: 42px;
    flex: 0 0 42px;
    padding: 0 0.5rem 0 78px;
    /* Blends with the sidebar — one chrome frame, no seam. */
    background: var(--color-chrome);
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
    /* Centered pills — the old flush-bottom Chrome merge made sense
     * when the canvas touched the bar; with the inset canvas the tabs
     * float in the chrome instead. */
    align-items: center;
    gap: 3px;
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    border-radius: 6px;
    transition: box-shadow 0.12s;
  }
  .tabs.drop-hot {
    box-shadow: inset 0 -2px 0 var(--color-brand);
  }
  .tab {
    position: relative;
    display: flex;
    align-items: center;
    height: 31px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
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
    box-shadow: 0 1px 2px rgba(15, 15, 15, 0.06);
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
  .kind-workbook { color: var(--color-fg-muted); }
  .kind-org { color: var(--color-fg-muted); }
  .kind-code { color: var(--color-fg-muted); }
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
    border-radius: 0 8px 8px 0;
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

  /* "+" new-tab button, sits at the right end of the strip — centered,
   * same as the (now centered) tab pills. */
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

  /* ── combined tab (split pill) ─────────────────────────────────── */
  .tab.combined {
    max-width: 360px;
    border-color: color-mix(in srgb, var(--color-brand) 30%, var(--color-border));
  }
  .tab.combined.active {
    border-color: color-mix(in srgb, var(--color-brand) 45%, var(--color-border-strong));
  }
  .tab-body.segment {
    border-radius: 6px;
    transition: background 0.1s;
  }
  .tab-body.segment.seg-focused {
    color: var(--color-fg);
    font-weight: 500;
  }
  .seg-divider {
    width: 1px;
    height: 14px;
    background: var(--color-border-strong);
    flex-shrink: 0;
  }
  .tab.merge-hot {
    box-shadow: inset 0 0 0 2px var(--color-brand);
    transform: scale(1.02);
  }

  /* provenance popover */
  .prov-scrim {
    position: fixed;
    inset: 0;
    z-index: 400;
    background: rgba(15, 15, 15, 0.18);
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding-top: 80px;
  }
  .prov-card {
    width: min(480px, calc(100vw - 48px));
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .prov-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .prov-head .close { opacity: 0.7; }
  .prov-title {
    font-size: 0.9rem;
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

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
