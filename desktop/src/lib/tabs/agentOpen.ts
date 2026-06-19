// Agent-driven tab open → chat-left / workbook-right split (demo FIX 2).
//
// When the user is chatting on the foreground create page and the agent
// opens a workbook (`work app open-tab <path>` → tab_command open), we want
// the layout to become chat-LEFT / workbook-RIGHT so the user watches the
// workbook get built live beside the conversation — NOT have the workbook
// replace the chat.
//
// Mechanism: open the live conversation as its OWN tab (`chat://waldo`,
// rendered by WaldoPanel), open the workbook tab, then use the existing
// panes split system to pair them — chat in the left pane, workbook in the
// right. Outside a foreground chat (no conversation), this is a plain open.

import { tabs } from "./store.svelte";
import { chatTabPath } from "./chatTab";
import { panes } from "$lib/viewer/panes.svelte";
import { chrome } from "$lib/ui/chrome.svelte";

const WALDO_SLUG = "waldo";

/** Open a path the AGENT asked to open. When there's a live conversation (the
 *  Waldo chat tab is open — submitting from the composer materializes it), this
 *  lands the workbook in a RIGHT split pane beside the chat so the user watches
 *  it get built next to the conversation; otherwise it's an ordinary open. */
export async function openFromAgent(path: string): Promise<void> {
  const chatPath = chatTabPath(WALDO_SLUG);
  // No live conversation to pair with → ordinary open (replace/focus).
  if (!tabs.tabs.some((t) => t.path === chatPath)) {
    await tabs.open(path);
    return;
  }

  // 1) Materialize the live conversation as a tab (left). Idempotent —
  //    focuses the existing chat tab if it's already open.
  await tabs.open(chatPath);

  // 2) Open the workbook tab (this focuses it).
  await tabs.open(path);

  // 3) Resolve both to tab ids and split: chat left, workbook right.
  //    `tabs.open` is async (host round-trip + reactive #apply); a second
  //    tab_command (the agent retrying open-tab) can fire a reconcile that
  //    collapses an in-flight 1-pane state to []. So drive the split through
  //    one self-healing helper that ALWAYS lands the deterministic 2-pane
  //    layout when both tabs exist, and re-assert once on the next tick to
  //    win that race. Idempotent: a settled chat|workbook split is left alone.
  ensureSplit(chatPath, path);
  queueMicrotask(() => ensureSplit(chatPath, path));

  // The canvas now shows docs (panes), not the home composer.
  chrome.mode = "doc";
}

/** Land (or restore) the chat-left / workbook-right split. Resolves both
 *  paths to live tab ids each call so it's robust to async tab opens and
 *  reconcile races; a no-op when the split already holds. */
function ensureSplit(chatPath: string, wbPath: string): void {
  const chatTab = tabs.tabs.find((t) => t.path === chatPath);
  const wbTab = tabs.tabs.find((t) => t.path === wbPath);
  if (!chatTab || !wbTab || chatTab.id === wbTab.id) return;

  const hasChat = panes.panes.some((p) => p.tabId === chatTab.id);
  const hasWb = panes.panes.some((p) => p.tabId === wbTab.id);
  // Already the intended split → just keep focus on the workbook.
  if (hasChat && hasWb && panes.panes.length === 2) {
    panes.focused = panes.panes.findIndex((p) => p.tabId === wbTab.id);
    return;
  }
  // Otherwise (empty/collapsed/stale) rebuild deterministically: chat is the
  // base (left), workbook splits onto the right.
  panes.splitWith(wbTab.id, "right", chatTab.id);
}
