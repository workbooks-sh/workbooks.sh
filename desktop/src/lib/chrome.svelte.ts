/**
 * chrome — shared top-chrome / shell UI state. The shell (App.svelte),
 * rail, titlebar, and views read from one store so the section label,
 * panels, doc-mode, and agent/terminal drawers stay in sync.
 *
 * Routing owns which main *app* view renders (svelte-simple-router).
 * `chrome` owns the surrounding shell state: app-vs-doc mode, the active
 * section label, the mutually-exclusive left panel, the right-side agent
 * drawer, the bottom terminal drawer, and cross-component nav requests.
 *
 * Modes:
 *   - "app" → main area shows the routed rail section (create/kanban/…).
 *             Doc tabs are inactive; the App pill is highlighted.
 *   - "doc" → main area shows the active document tab. The App pill is
 *             dim; the active doc tab is highlighted.
 */

export type ChromeMode = "app" | "doc";

/** The left-side panel slot is mutually exclusive — files, search, or
 *  none. Two competing panels eat too much chrome width. */
export type LeftPanel = "files" | "search" | null;

class ChromeStore {
  /** Active rail-section label (shown in the titlebar). Mirrors the
   *  current route; the router sets it on navigate. */
  section = $state<string>("Create");

  /** Whether the main area renders the routed section or the active doc
   *  tab. Doc tabs flip this to "doc"; the App pill flips it back. */
  mode = $state<ChromeMode>("app");

  leftPanel = $state<LeftPanel>(null);

  /** Right-side Agent panel visibility (⌘J). */
  agentOpen = $state<boolean>(false);

  /** Bottom Terminal drawer visibility (⌃`). */
  terminalOpen = $state<boolean>(false);

  /** AI command-palette modal (home view). */
  paletteOpen = $state<boolean>(false);

  /** Bookmarks popover, anchored next to the titlebar bookmark icon.
   *  The titlebar captures the anchor element on click; App.svelte
   *  mounts the popover so it positions relative to that button. */
  bookmarksOpen = $state<boolean>(false);
  bookmarksAnchor = $state<HTMLElement | null>(null);

  /** Cross-component nav request. A deep-link source (e.g. the chat
   *  header's "Edit agent") sets this to jump the rail to a section,
   *  optionally with a Settings sub-tab. App.svelte consumes + clears. */
  requestedSection = $state<string | null>(null);
  settingsTab = $state<string | null>(null);

  toggleFiles() {
    this.leftPanel = this.leftPanel === "files" ? null : "files";
  }
  toggleSearch() {
    this.leftPanel = this.leftPanel === "search" ? null : "search";
  }
  openFiles() {
    this.leftPanel = "files";
  }
  openSearch() {
    this.leftPanel = "search";
  }
  closeLeft() {
    this.leftPanel = null;
  }

  /** Navigate the rail to `section` (+ optional Settings sub-tab) in one
   *  call. App.svelte owns the router; this is the request channel. */
  navigateTo(section: string, settingsTab?: string) {
    if (settingsTab) this.settingsTab = settingsTab;
    this.requestedSection = section;
  }
}

export const chrome = new ChromeStore();
