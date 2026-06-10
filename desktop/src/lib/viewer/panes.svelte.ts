/**
 * panes — split-view layout state for the doc area (epic wb-5fl).
 *
 * Single-pane is the default and is IMPLICIT: `panes` stays empty and
 * DocViewer follows tabs.active as before. A split materializes the
 * pane list (left→right, max 3); each pane shows one tab. Closing a
 * tab drops its pane (reconcile); dropping back to one pane returns
 * to implicit mode. Pure frontend state — the host's tab list stays
 * the single source of truth for what's open.
 */
import { tabs } from "$lib/tabs/store.svelte";

export type SplitSide = "left" | "right";

export interface Pane {
  id: number;
  tabId: string;
}

const MAX_PANES = 3;

class PaneStore {
  panes = $state<Pane[]>([]);
  focused = $state(0);
  /** Width fractions, same length as panes (empty in implicit mode). */
  sizes = $state<number[]>([]);
  #nextId = 1;

  get isSplit(): boolean {
    return this.panes.length > 1;
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
  }

  /** Drop panes whose tab no longer exists. Call when tabs change. */
  reconcile(openIds: Set<string>) {
    if (this.panes.length === 0) return;
    const kept = this.panes.filter((p) => openIds.has(p.tabId));
    if (kept.length !== this.panes.length) {
      this.panes = kept.length > 1 ? kept : [];
      this.sizes = this.panes.map(() => 1 / this.panes.length);
      this.focused = Math.min(this.focused, Math.max(0, this.panes.length - 1));
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
