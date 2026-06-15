// Live-conversation-as-tab helpers (demo-features).
//
// A conversation with Waldo opens as its OWN browser TAB so the user can
// navigate to other tabs and come BACK to the live chat. The tab path uses
// the `chat://<slug>` scheme so classifyKind routes it to WaldoPanel
// (rendered fullscreen) instead of the generic viewers.
//
// The dock panel and this tab both mount WaldoPanel, which reads the
// module-singleton chatSession + geminiLive — so they reflect the SAME
// running conversation. Opening the tab is idempotent (tab_open focuses an
// existing tab by path).

import { tabs } from "./store.svelte";

/** Tab path for a live conversation with an agent slug. */
export function chatTabPath(slug: string): string {
  return `chat://${slug}`;
}

/** Slug encoded in a `chat://<slug>` tab path (null if not one). */
export function chatSlugFromPath(path: string): string | null {
  const m = path.match(/^chat:\/\/(.+)$/i);
  return m ? decodeURIComponent(m[1]) : null;
}

/** Open (or focus) the live conversation as a tab. Idempotent — a second
 *  call focuses the existing tab rather than spawning a duplicate. */
export async function openChatTab(slug: string): Promise<void> {
  await tabs.open(chatTabPath(slug));
}
