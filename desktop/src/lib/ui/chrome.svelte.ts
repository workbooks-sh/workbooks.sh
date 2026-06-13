/**
 * Top-chrome state shared between +layout.svelte (renders the Titlebar)
 * and +page.svelte (owns the rail + main area). Keeping the Titlebar in
 * the layout — and feeding it from one place — keeps the top strip
 * exactly 36px tall on every section.
 *
 * Modes:
 *   - "app"  → main area shows the active rail section (chat/kanban/settings).
 *              Doc tabs in the titlebar are inactive; the "App" pill is
 *              highlighted.
 *   - "doc"  → main area shows the active document tab (workbook / org /
 *              code / text). The App pill is dim; the active doc tab is
 *              highlighted.
 *
 * Switching: clicking the App pill or a left-rail icon → "app". Clicking
 * any doc tab, or opening a new file from the right-rail file tree → "doc".
 */

export type ChromeMode = "app" | "doc";

/** The left-side panel slot is mutually exclusive — one of these or
 *  none. Two competing left panels at once eats too much chrome width
 *  and the user never asked for both. */
export type LeftPanel = "files" | "search" | null;

class ChromeStore {
  /** Active rail-tab label (shown after the product name when in app mode). */
  section = $state<string>("");

  /** Arc-style left sidebar (folders + apps). Open by default; the
   *  titlebar toggle + ⌘B flip it. Persisted so the choice survives
   *  relaunch. */
  sidebarOpen = $state<boolean>(
    typeof localStorage === "undefined"
      ? true
      : localStorage.getItem("chrome.sidebarOpen") !== "0",
  );
  toggleSidebar() {
    this.sidebarOpen = !this.sidebarOpen;
    try {
      localStorage.setItem("chrome.sidebarOpen", this.sidebarOpen ? "1" : "0");
    } catch {
      /* private mode etc. — non-fatal */
    }
  }

  /** Whether the main area renders the rail section or the active doc tab. */
  mode = $state<ChromeMode>("app");

  /** Which left-side panel is open (file tree, search, or none). */
  leftPanel = $state<LeftPanel>(null);

  /** Convenience setters — keep the mutual exclusion in one place so
   *  callers don't have to remember to clear the sibling.
   *
   *  Note (wb-i38o.36): the "files" panel no longer has a titlebar
   *  toggle. `toggleFiles` is still here because the rail uses it
   *  when the user clicks the already-active package — that gesture
   *  collapses or expands the package panel. Cross-package file
   *  lookup is the search panel's job. */
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

  /** Bookmarks popover anchored next to the titlebar's bookmark icon.
   *  Anchor element is captured by the Titlebar when the user clicks
   *  the icon; +page.svelte mounts the popover. */
  bookmarksOpen = $state<boolean>(false);
  bookmarksAnchor = $state<HTMLElement | null>(null);

  /** Nexus switcher popover anchored to the titlebar engine chip
   *  (wb-aakl.9). Same anchor pattern as bookmarks. */
  nexusOpen = $state<boolean>(false);
  nexusAnchor = $state<HTMLElement | null>(null);

  // The right-side panel is now the extension dock (wb-aakl.14, dock store);
  // the old chrome.agentOpen boolean is gone — the agent is one dock panel.

  /** Whether the AI command palette modal is open (wb-5hc0 / wb-dj5r).
   *  Other surfaces watch this so they don't compete for attention with
   *  the palette — e.g. the global LiveBar hides while the palette is
   *  up because the palette renders its own voice status inline. */
  paletteOpen = $state<boolean>(false);

  /** Cross-component navigation request. Components like the chat
   *  header set this to jump the rail to a specific section (e.g.
   *  "settings" with `settingsTab = 'agents'`); +page.svelte's effect
   *  flips `active` and clears the request. */
  requestedSection = $state<string | null>(null);
  /** Which Settings sub-tab to open when SettingsContainer next mounts
   *  or when chrome.requestedSection === "settings". Cleared by the
   *  container after it consumes the value. */
  settingsTab = $state<string | null>(null);

  /** Navigate the rail to `section` and (optionally) preselect a
   *  Settings sub-tab in one call. +page.svelte owns the rail state;
   *  this is the cross-component request channel into it. */
  navigateTo(section: string, settingsTab?: string) {
    if (settingsTab) this.settingsTab = settingsTab;
    this.requestedSection = section;
  }
}

export const chrome = new ChromeStore();
