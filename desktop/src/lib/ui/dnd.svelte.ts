/**
 * dnd — the one shared drag payload for shell drag-and-drop.
 *
 * HTML5 dataTransfer is unreadable during dragover, so every drag
 * source mirrors its payload here and every drop zone reads it to
 * decide whether (and how) to light up. Canon (epic wb-5fl):
 *
 *   edge-drop   = split (give it its own space)
 *   center-drop = open in that pane (give it to the surface)
 *   tab strip   = new tab
 *   tile grid   = pin
 */
import { invoke } from "@tauri-apps/api/core";

export type DragPayload =
  | { type: "workbook"; path: string; title: string }
  | { type: "app"; id: string; name: string }
  | { type: "tab"; tabId: string; path: string; title: string };

class DndStore {
  payload = $state<DragPayload | null>(null);

  start(p: DragPayload, e?: DragEvent) {
    this.payload = p;
    if (e?.dataTransfer) {
      e.dataTransfer.effectAllowed = "copyMove";
      e.dataTransfer.setData(
        "text/plain",
        p.type === "app" ? p.name : p.path,
      );
    }
  }

  end() {
    this.payload = null;
  }

  /** Display title for previews/pills. */
  get title(): string {
    const p = this.payload;
    if (!p) return "";
    return p.type === "app" ? p.name : p.title;
  }

  /** Resolve the payload to an openable path. Apps resolve their
   *  workbook via the host; tabs/workbooks carry the path already. */
  async resolvePath(): Promise<string | null> {
    const p = this.payload;
    if (!p) return null;
    if (p.type === "app") {
      try {
        return await invoke<string>("package_app_workbook", { name: p.id });
      } catch {
        return null;
      }
    }
    return p.path;
  }
}

export const dnd = new DndStore();
