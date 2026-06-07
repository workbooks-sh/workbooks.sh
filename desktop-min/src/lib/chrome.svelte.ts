/**
 * chrome — shared top-chrome / shell UI state. The shell (App.svelte),
 * rail, and views read from one store so the section label, panels, and
 * agent/terminal drawers stay in sync.
 *
 * Routing owns which main view renders (svelte-simple-router). `chrome`
 * owns the surrounding shell state: the active section label, the
 * mutually-exclusive left panel, and the right-side agent drawer.
 */

/** The left-side panel slot is mutually exclusive — files, search, or
 *  none. Two competing panels eat too much chrome width. */
export type LeftPanel = "files" | "search" | null;

class ChromeStore {
  /** Active rail-section label (shown in the titlebar). Mirrors the
   *  current route; the rail sets it on navigate. */
  section = $state<string>("Create");

  leftPanel = $state<LeftPanel>(null);

  /** Right-side Agent panel visibility (⌘J). */
  agentOpen = $state<boolean>(false);

  /** Bottom Terminal drawer visibility (⌃`). */
  terminalOpen = $state<boolean>(false);

  /** AI command-palette modal (home view). */
  paletteOpen = $state<boolean>(false);

  toggleFiles() {
    this.leftPanel = this.leftPanel === "files" ? null : "files";
  }
  toggleSearch() {
    this.leftPanel = this.leftPanel === "search" ? null : "search";
  }
  closeLeft() {
    this.leftPanel = null;
  }
}

export const chrome = new ChromeStore();
