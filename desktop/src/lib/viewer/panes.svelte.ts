/**
 * panes — split-view layout state for the doc area (epic wb-5fl).
 *
 * Single-pane is the default and is IMPLICIT: `panes` stays empty and
 * DocViewer follows tabs.active as before. A split materializes the
 * pane list (left→right, max 4); each pane shows one tab. Closing a
 * tab drops its pane (reconcile); dropping back to one pane returns
 * to implicit mode. Pure frontend state — the host's tab list stays
 * the single source of truth for what's open.
 */
import { tabs } from "$lib/tabs/store.svelte";

export type SplitSide = "left" | "right";
/** How the panes tile. `row` = side-by-side resizable columns (the 2-up
 *  default). `grid` = a real 2-column grid that quadrants 4-up (2×2) and
 *  lays 3-up out sensibly — never N skinny columns (work demo TASK 5). */
export type PaneLayout = "row" | "grid";

export interface Pane {
  id: number;
  tabId: string;
}

const MAX_PANES = 4;

class PaneStore {
  panes = $state<Pane[]>([]);
  focused = $state(0);
  /** Width fractions, same length as panes (empty in implicit mode).
   *  Only meaningful in `row` layout. */
  sizes = $state<number[]>([]);
  /** Tiling mode. Auto-set: 2-up → row, 3/4-up → grid; the split-control
   *  glyphs (columns / squares-four) let the user force either. */
  layout = $state<PaneLayout>("row");
  #nextId = 1;

  get isSplit(): boolean {
    return this.panes.length > 1;
  }

  /** True when the current layout tiles as a grid (3+ panes default, or
   *  forced grid). Drives DocViewer's grid-vs-row branch. */
  get isGrid(): boolean {
    return this.layout === "grid" && this.panes.length > 1;
  }

  /** CSS grid-template for the doc area when `isGrid`. 2 cols always; rows
   *  derive from pane count. 4 panes → 2×2 quadrants; 3 → 2 cols, the 3rd
   *  spanning the full bottom row. */
  get gridColumns(): string {
    return "1fr 1fr";
  }
  get gridRows(): string {
    const n = this.panes.length;
    const rows = Math.max(1, Math.ceil(n / 2));
    return Array.from({ length: rows }, () => "1fr").join(" ");
  }
  /** Per-pane grid-column span. With an odd count, the LAST pane spans both
   *  columns so 3-up reads as two-on-top, one-full-width-below. */
  spanFor(index: number): string {
    const n = this.panes.length;
    const odd = n % 2 === 1;
    if (odd && index === n - 1) return "1 / -1";
    return "auto";
  }

  /** Force a tiling mode (split-control glyphs). */
  setLayout(mode: PaneLayout) {
    this.layout = mode;
  }

  /** Pick the natural layout for the current pane count: 2-up is a resizable
   *  row, 3/4-up quadrants into a grid. Called whenever the pane set grows. */
  #autoLayout() {
    this.layout = this.panes.length >= 3 ? "grid" : "row";
  }

  /** Split: put `tabId` in a new pane on `side`. From implicit mode the
   *  prior doc becomes the other pane — pass `baseTabId` (the tab that
   *  was showing BEFORE the drop opened the new one; opening focuses
   *  the new tab, so reading tabs.activeId here would see the incoming
   *  tab and collapse the split). At MAX_PANES the new pane replaces
   *  the edge pane on that side instead of growing. */
  splitWith(tabId: string, side: SplitSide, baseTabId?: string | null) {
    const fresh = { id: this.#nextId++, tabId };
    // A 1-pane list is implicit mode with leftovers — the visible doc
    // is tabs.active (clicks moved on without updating the pane), so
    // rebuild from the base rather than appending to stale state.
    if (this.panes.length <= 1) {
      const cur = baseTabId ?? tabs.activeId;
      const base: Pane[] =
        cur && cur !== tabId ? [{ id: this.#nextId++, tabId: cur }] : [];
      this.panes = side === "left" ? [fresh, ...base] : [...base, fresh];
    } else if (this.panes.some((p) => p.tabId === tabId)) {
      // Already visible — just focus it.
      this.focused = this.panes.findIndex((p) => p.tabId === tabId);
      return;
    } else if (this.panes.length >= MAX_PANES) {
      const next = [...this.panes];
      next[side === "left" ? 0 : next.length - 1] = fresh;
      this.panes = next;
    } else {
      this.panes =
        side === "left" ? [fresh, ...this.panes] : [...this.panes, fresh];
    }
    this.sizes = this.panes.map(() => 1 / this.panes.length);
    this.focused = side === "left" ? 0 : this.panes.length - 1;
    this.#autoLayout();
  }

  /** Show a tab in an existing pane (center-drop / strip click while split). */
  showInPane(index: number, tabId: string) {
    if (index < 0 || index >= this.panes.length) return;
    const next = [...this.panes];
    next[index] = { ...next[index], tabId };
    this.panes = next;
    this.focused = index;
  }

  closePane(index: number) {
    const kept = this.panes.filter((_, i) => i !== index);
    this.panes = kept.length > 1 ? kept : [];
    this.sizes = this.panes.map(() => 1 / this.panes.length);
    this.focused = Math.min(this.focused, Math.max(0, this.panes.length - 1));
    this.#autoLayout();
  }

  /** Drop panes whose tab no longer exists. Call when tabs change. */
  reconcile(openIds: Set<string>) {
    if (this.panes.length === 0) return;
    const kept = this.panes.filter((p) => openIds.has(p.tabId));
    if (kept.length !== this.panes.length) {
      this.panes = kept.length > 1 ? kept : [];
      this.sizes = this.panes.map(() => 1 / this.panes.length);
      this.focused = Math.min(this.focused, Math.max(0, this.panes.length - 1));
      this.#autoLayout();
    }
  }

  /** Divider drag: shift width between pane i and i+1. `delta` is a
   *  fraction of the total doc width. */
  resize(i: number, delta: number) {
    if (i < 0 || i + 1 >= this.sizes.length) return;
    const next = [...this.sizes];
    const moved = Math.max(
      0.15,
      Math.min(next[i] + delta, next[i] + next[i + 1] - 0.15),
    );
    next[i + 1] = next[i] + next[i + 1] - moved;
    next[i] = moved;
    this.sizes = next;
  }
}

export const panes = new PaneStore();
