// Toolkit panel manifest (wb-aakl.15) — how a toolkit declares a dock UI.
//
// This is the component EXEC shape from the unified-toolkit epic (wb-rhs)
// rendered in the browser instead of as a page: a toolkit ships an HTML
// entry + an icon + a title, and registers it as a dock panel. The host
// stays primitives-only — the manifest just maps onto dock.register, and
// the toolkit's UI drives the browser through the Browser SDK
// (/browser-sdk.js) over postMessage.

import type { Component } from "svelte";
import { dock } from "$lib/bridge/dock.svelte";

export interface ToolkitPanelManifest {
  /** Stable id (toolbar/keybinding key). */
  id: string;
  title: string;
  /** Toolbar icon — a phosphor-svelte (or any) component. */
  icon?: Component<any> | null;
  /** The toolkit UI entry. A URL (iframe-mounted, sandboxed — the default
   *  trust rung for loaded artifacts) or, for trusted/first-party panels,
   *  a Svelte component (DOM-mounted). */
  entry: { iframeSrc: string } | { component: Component<any> };
}

/** Register a toolkit panel into the extension dock. Idempotent by id.
 *  Returns an unregister fn. */
export function registerToolkitPanel(m: ToolkitPanelManifest): () => void {
  dock.register({
    id: m.id,
    title: m.title,
    icon: m.icon ?? null,
    ...("iframeSrc" in m.entry
      ? { iframeSrc: m.entry.iframeSrc }
      : { component: m.entry.component }),
  });
  return () => dock.unregister(m.id);
}
