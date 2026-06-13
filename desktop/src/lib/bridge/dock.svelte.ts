// Extension dock (wb-aakl.14) — the free-form right panel.
//
// Replaces the single-purpose agent drawer (chrome.agentOpen → AgentPanel)
// with a REGISTRY: any number of panels register a dock entry; the titlebar
// toolbar shows an icon per entry; clicking toggles it open in the right
// dock. The agent panel becomes just one (flag-gated) registrant. Toolkits
// with UI (the Browser SDK, wb-aakl.15) register here too — DOM-mounted
// Svelte components inherit the theme for free; iframe-mounted toolkit UIs
// use the wb-theme postMessage shim (DockHost).
//
// The core canvas + titlebar stay static; the dock is the only free-form
// zone. One panel is active at a time (a tabbed multi-panel dock is a
// later refinement).

import type { Component } from "svelte";

export interface DockPanel {
  /** Stable id (also the toolbar/keybinding key). */
  id: string;
  title: string;
  /** Toolbar icon — a phosphor-svelte (or any) component, or null. */
  icon?: Component<any> | null;
  /** Render only the icon in the toolbar (no text label) — for a custom
   *  wordmark that already reads as the name (e.g. Waldo). */
  iconOnly?: boolean;
  /** Eager DOM-mounted component… */
  component?: Component<any>;
  /** …or a lazy loader (resolved + cached on first activation). */
  load?: () => Promise<{ default: Component<any> }>;
  /** …or an iframe-mounted toolkit UI (themed via postMessage). */
  iframeSrc?: string;
  /** Props passed to a component panel. */
  props?: Record<string, unknown>;
}

const WIDTH_KEY = "wb.dock.width";
const MIN_W = 320;
const MAX_W = 720;

function initialWidth(): number {
  if (typeof localStorage === "undefined") return 420;
  const raw = Number(localStorage.getItem(WIDTH_KEY));
  return Number.isFinite(raw) && raw >= MIN_W && raw <= MAX_W ? raw : 420;
}

class DockStore {
  panels = $state<DockPanel[]>([]);
  activeId = $state<string | null>(null);
  width = $state<number>(initialWidth());

  get active(): DockPanel | null {
    return this.panels.find((p) => p.id === this.activeId) ?? null;
  }

  /** Register a panel (idempotent by id). Keeps registration order =
   *  toolbar order. */
  register(panel: DockPanel): void {
    if (this.panels.some((p) => p.id === panel.id)) return;
    this.panels = [...this.panels, panel];
  }

  unregister(id: string): void {
    this.panels = this.panels.filter((p) => p.id !== id);
    if (this.activeId === id) this.activeId = null;
  }

  toggle(id: string): void {
    this.activeId = this.activeId === id ? null : id;
  }

  open(id: string): void {
    if (this.panels.some((p) => p.id === id)) this.activeId = id;
  }

  close(): void {
    this.activeId = null;
  }

  isOpen(id: string): boolean {
    return this.activeId === id;
  }

  setWidth(w: number): void {
    this.width = Math.max(MIN_W, Math.min(MAX_W, Math.round(w)));
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.setItem(WIDTH_KEY, String(this.width));
      } catch {
        /* best-effort */
      }
    }
  }
}

export const dock = new DockStore();
