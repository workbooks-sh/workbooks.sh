// Chrome command registry (wb-aakl.17) — "my app however I want it".
//
// The titlebar overflow (⌄) menu, the command palette, and the tab context
// menu all read from this one registry instead of hardcoded markup. Built-
// ins register through the same seam (dogfood rule), and a toolkit (via the
// Browser SDK) registers commands the same way — so the chrome is
// extensible, not fixed.

import type { Component } from "svelte";

export type CommandGroup =
  | "menu" // titlebar ⌄ overflow menu
  | "global" // palette / general actions
  | "tab"; // per-tab context menu

export interface ChromeCommand {
  id: string;
  label: string;
  group: CommandGroup;
  icon?: Component<any> | null;
  /** Display-only shortcut hint (e.g. "⌘K"). Binding lives in the host. */
  shortcut?: string;
  /** Lower sorts first within a group. */
  order?: number;
  /** Run the command. `ctx` is group-specific (e.g. the tab for "tab"). */
  run: (ctx?: unknown) => void;
}

class CommandRegistry {
  commands = $state<ChromeCommand[]>([]);

  register(c: ChromeCommand): () => void {
    if (!this.commands.some((x) => x.id === c.id)) {
      this.commands = [...this.commands, c];
    }
    return () => this.unregister(c.id);
  }

  unregister(id: string): void {
    this.commands = this.commands.filter((c) => c.id !== id);
  }

  byGroup(group: CommandGroup): ChromeCommand[] {
    return this.commands
      .filter((c) => c.group === group)
      .slice()
      .sort((a, b) => (a.order ?? 100) - (b.order ?? 100));
  }

  /** Fuzzy-ish match for the palette: label substring, any group. */
  match(query: string): ChromeCommand[] {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    return this.commands
      .filter((c) => c.label.toLowerCase().includes(q))
      .sort((a, b) => {
        const as = a.label.toLowerCase().startsWith(q) ? 0 : 1;
        const bs = b.label.toLowerCase().startsWith(q) ? 0 : 1;
        return as - bs || (a.order ?? 100) - (b.order ?? 100);
      })
      .slice(0, 8);
  }

  run(id: string, ctx?: unknown): void {
    this.commands.find((c) => c.id === id)?.run(ctx);
  }
}

export const commands = new CommandRegistry();
