<script lang="ts">
  /**
   * Titlebar — the single, always-36px top chrome.
   *
   * Layout (left → right):
   *   [78px traffic-light padding]
   *   [Search] [Bookmarks] [Terminal]
   *   [App pill] [doc tab] [doc tab] ...
   *   [spacer]
   *
   * The package file/grid view is reachable per-package from the rail
   * (selecting a package opens the panel via `chrome.openFiles`); the
   * search button opens the command palette (⌘K) for cross-package
   * file lookup (wb-i38o.36).
   *
   * The "App pill" is a singular tab that represents the main app
   * sections (chat / kanban / settings); each remaining tab is a
   * browser-style document tab from the tabs store.
   *
   * Tauri drag: the bar surface is `data-tauri-drag-region` so the user
   * can drag from any non-interactive part. Buttons opt out with
   * `data-tauri-drag-region="false"`. macOS uses `titleBarStyle:
   * "Overlay"` with 78px left padding reserving traffic-light space.
   */
  import {
    X,
    AppWindow,
    Search,
    Bookmark,
    MessageCircle,
    Terminal as TerminalIcon,
  } from "@lucide/svelte";
  import { terminalDrawer } from "$lib/bridge/terminal.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import type { Tab } from "$lib/tabs/types";
  import { geminiLive } from "$lib/live/gemini.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { wizard } from "$lib/setup/wizard.svelte";

  // Engine connection state, surfaced (offline-first: the app runs without it).
  const engine = $derived.by(() => {
    const s = sidecar.status.state;
    if (s === "ready") return { label: "Engine", cls: "ok", title: "Engine connected — click to manage" };
    if (s === "starting" || s === "restarting")
      return { label: "Engine…", cls: "pending", title: "Engine starting" };
    return { label: "No engine", cls: "off", title: "Engine not connected — click to set up" };
  });

  function kindGlyph(kind: Tab["kind"]): string {
    switch (kind) {
      case "workbook": return "◆";
      case "org": return "◉";
      case "code": return "{ }";
      case "text":
      default: return "—";
    }
  }

  const searchOpen = $derived(chrome.leftPanel === "search");

  // Bookmark popover state owned here; the popover itself is mounted
  // in +page.svelte so it positions relative to the bookmark button.
  let bookmarkBtnEl: HTMLButtonElement | undefined = $state();
  function toggleBookmarks() {
    chrome.bookmarksAnchor = bookmarkBtnEl ?? null;
    chrome.bookmarksOpen = !chrome.bookmarksOpen;
  }

  function focusApp() {
    chrome.mode = "app";
  }

  async function focusDoc(id: string) {
    chrome.mode = "doc";
    await tabsStore.focus(id);
  }

  async function closeDoc(id: string, e: MouseEvent) {
    e.stopPropagation();
    await tabsStore.close(id);
    if (tabsStore.tabs.length === 0) chrome.mode = "app";
  }
</script>

<div class="titlebar" data-tauri-drag-region role="presentation">
  <div class="left-tools">
    <button
      type="button"
      class="icon-btn"
      data-tauri-drag-region="false"
      title="Search (⌘K)"
      aria-label="Search (⌘K)"
      aria-pressed={searchOpen}
      onclick={() => chrome.toggleSearch()}
    >
      <Search size={14} strokeWidth={1.8} />
    </button>
    <button
      type="button"
      class="icon-btn"
      data-tauri-drag-region="false"
      title="Bookmarks"
      aria-label="Bookmarks"
      aria-pressed={chrome.bookmarksOpen}
      bind:this={bookmarkBtnEl}
      onclick={toggleBookmarks}
    >
      <Bookmark size={14} strokeWidth={1.8} />
    </button>
    <button
      type="button"
      class="icon-btn"
      data-tauri-drag-region="false"
      title="Terminal (⌃`)"
      aria-label="Toggle terminal"
      aria-pressed={terminalDrawer.open}
      onclick={() => terminalDrawer.toggle()}
    >
      <TerminalIcon size={14} strokeWidth={1.8} />
    </button>
  </div>

  <button
    type="button"
    class="pill app-pill"
    class:active={chrome.mode === "app"}
    data-tauri-drag-region="false"
    title="App ({chrome.section || "main"})"
    aria-pressed={chrome.mode === "app"}
    onclick={focusApp}
  >
    <AppWindow size={12} strokeWidth={2} />
    <span class="pill-label">{chrome.section || "App"}</span>
  </button>

  <div class="tabs" role="tablist">
    {#each tabsStore.tabs as tab (tab.id)}
      {@const active = chrome.mode === "doc" && tabsStore.activeId === tab.id}
      <div
        class="tab"
        class:active
        role="tab"
        aria-selected={active}
        title={tab.path}
      >
        <button
          type="button"
          class="tab-body"
          data-tauri-drag-region="false"
          onclick={() => focusDoc(tab.id)}
        >
          <span class="kind kind-{tab.kind}">{kindGlyph(tab.kind)}</span>
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
          <X size={11} strokeWidth={2} />
        </button>
      </div>
    {/each}
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
    {engine.label}
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
    <MessageCircle size={12} strokeWidth={2} />
    <span>Agent</span>
    {#if geminiLive.active}
      <span class="live-dot" class:muted={geminiLive.muted} aria-hidden="true"></span>
    {/if}
  </button>
</div>

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

  .left-tools {
    display: flex;
    align-items: center;
    gap: 2px;
    flex-shrink: 0;
  }

  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    height: 24px;
    width: 24px;
    border-radius: 6px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.1s, color 0.1s;
  }
  .icon-btn:hover {
    background: var(--color-page);
    color: var(--color-fg);
  }
  .icon-btn[aria-pressed="true"] {
    background: var(--color-page);
    color: var(--color-fg);
  }

  .app-pill {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    align-self: center;
    height: 24px;
    padding: 0 0.65rem;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    background: var(--color-page);
    color: var(--color-fg-muted);
    font-size: 12px;
    font-family: inherit;
    cursor: pointer;
    flex-shrink: 0;
  }
  .app-pill:hover { color: var(--color-fg); }
  .app-pill.active {
    background: var(--color-surface);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .pill-label {
    font-weight: 500;
    letter-spacing: -0.005em;
  }

  .engine {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    align-self: center;
    height: 22px;
    padding: 0 0.5rem;
    border: 1px solid transparent;
    border-radius: 999px;
    background: transparent;
    font-size: 11px;
    font-weight: 500;
    font-family: inherit;
    color: var(--color-fg-subtle);
    flex-shrink: 0;
    cursor: pointer;
    user-select: none;
  }
  .engine:hover { border-color: var(--color-border); background: var(--color-page); }
  .engine-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-fg-subtle);
  }
  .engine-ok { color: var(--color-fg-muted); }
  .engine-ok .engine-dot { background: var(--color-ok); }
  .engine-pending .engine-dot { background: var(--color-warn); }
  .engine-off .engine-dot { background: var(--color-fg-subtle); }

  .tabs {
    display: flex;
    flex-direction: row;
    align-items: flex-end;
    gap: 2px;
    min-width: 0;
    overflow-x: auto;
    overflow-y: hidden;
    scrollbar-width: thin;
  }
  .tab {
    position: relative;
    display: flex;
    align-items: center;
    height: 28px;
    margin-bottom: 0;
    border: 1px solid var(--color-border);
    border-bottom: none;
    border-radius: 7px 7px 0 0;
    background: transparent;
    color: var(--color-fg-muted);
    min-width: 0;
    max-width: 200px;
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
    padding: 0 0.45rem 0 0.6rem;
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
  }
  .kind {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 12px;
    font-size: 10px;
    opacity: 0.55;
    font-family: ui-monospace, SFMono-Regular, monospace;
    flex-shrink: 0;
  }
  .kind-workbook { color: #5b8cff; opacity: 0.9; }
  .kind-org { color: #10b981; opacity: 0.9; }
  .kind-code { color: #a855f7; opacity: 0.9; }
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
    padding: 0 0.45rem;
    height: 100%;
    border-radius: 0 7px 0 0;
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

  .spacer { flex: 1 1 auto; }

  /* Agent button — pinned to the right edge of the titlebar, mirrors
   * the App pill weight on the left so the bar reads as
   * "[tools] [pill]      [agent]". */
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
