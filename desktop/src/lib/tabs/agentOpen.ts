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
import { chatBackdrop } from "$lib/home/chatBackdrop.svelte";
import { chrome } from "$lib/ui/chrome.svelte";

const WALDO_SLUG = "waldo";

/** Open a path the AGENT asked to open. In a foreground create chat this
 *  lands it in a right split pane beside the conversation; otherwise it's
 *  an ordinary open. */
export async function openFromAgent(path: string): Promise<void> {
  // Not in a foreground conversation → ordinary open (replace/focus).
  if (!chatBackdrop.active) {
    await tabs.open(path);
    return;
  }

  // 1) Materialize the live conversation as a tab (left). Idempotent —
  //    focuses the existing chat tab if it's already open.
  const chatPath = chatTabPath(WALDO_SLUG);
  await tabs.open(chatPath);

  // 2) Open the workbook tab (this focuses it).
  await tabs.open(path);

  // 3) Resolve both to tab ids and split: chat left, workbook right.
  const chatTab = tabs.tabs.find((t) => t.path === chatPath);
  const wbTab = tabs.tabs.find((t) => t.path === path);
  if (chatTab && wbTab && chatTab.id !== wbTab.id) {
    // Idempotent: the agent often retries open-tab (e.g. fixing a quoted
    // path). If the workbook already sits in a pane, just focus it —
    // splitting again would grow a third pane.
    if (panes.panes.some((p) => p.tabId === wbTab.id)) {
      panes.focused = panes.panes.findIndex((p) => p.tabId === wbTab.id);
    } else {
      // Build the split explicitly so order is deterministic regardless of
      // which tab is currently active: chat is the base (left), workbook
      // splits onto the right.
      panes.splitWith(wbTab.id, "right", chatTab.id);
    }
  }

  // The canvas now shows docs (panes), not the home composer.
  chrome.mode = "doc";
}
