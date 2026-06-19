// Component-toolkit artifact flow — the bridge between an agent's
// `component_artifact` telemetry event and an open workbook tab.
//
// The component-toolkit EXEC shape produces a component/artifact (an
// HTML/workbook file written to the user's workspace). When the runtime
// emits the `component_artifact` event, the chat session pushes an
// ArtifactBlock AND calls `autoOpen()` here so the user immediately lands
// on the component to keep iterating with the agent.
//
// Open is idempotent per artifact key (reproject re-walks every event on
// each ingest), so we track which keys we've already opened.
//
// In the browser preview (webHost mock) there's no runtime to write the
// file to disk, so the mock agent registers the artifact bytes here via
// `register()`; `read_file_bytes_base64` in webHost.ts serves them. In the
// packaged app the runtime writes the real file and this registry is unused
// (read_file_bytes_base64 reads disk).

import { tabs } from "$lib/tabs/store.svelte";
import { chrome } from "$lib/ui/chrome.svelte";
import { openFromAgent } from "$lib/tabs/agentOpen";

class ComponentArtifacts {
  /** Artifact keys already auto-opened this run (dedup the reproject loop). */
  #opened = new Set<string>();
  /** Browser-preview byte store: path → UTF-8 HTML the mock agent produced. */
  #bytes = new Map<string, string>();

  /** Per-path reload counter. Bumped whenever the artifact at a path is
   *  re-written (an "updated" event), so an already-open WorkbookView tab
   *  re-reads the new bytes instead of showing the stale revision. Reactive:
   *  WorkbookView reads `revisionOf(path)` and reloads when it changes. */
  revisions = $state<Record<string, number>>({});

  /** Reactive read of a path's reload counter (0 if never written). */
  revisionOf(path: string): number {
    return this.revisions[path] ?? 0;
  }

  /** React to a `component_artifact` event exactly once per event key
   *  (reproject re-walks every event on each ingest, so this is called
   *  repeatedly). On first sight: open the artifact as a tab, and on an
   *  "updated" event also bump the path's reload counter so an
   *  already-open tab re-reads the new bytes. */
  handle(key: string, path: string, action: "created" | "updated"): void {
    if (this.#opened.has(key)) return;
    this.#opened.add(key);
    if (action === "updated") this.markUpdated(path);
    // Spawn the freshly-built app in a RIGHT split pane beside the live
    // conversation (chat-left / app-right) instead of yanking the user to a
    // new full tab — they watch the agent talk AND see what it built. Falls
    // back to a plain open outside a foreground chat. The card's "Open" button
    // still uses open() to focus it on demand.
    void openFromAgent(path);
  }

  /** Open (or focus) the artifact as a workbook tab and switch the canvas
   *  to doc mode so the component shows. Called by the auto-open path and
   *  by the chat card's "Open" button. */
  async open(path: string): Promise<void> {
    try {
      await tabs.open(path);
      chrome.mode = "doc";
    } catch (e) {
      console.warn("[artifacts] open failed", path, e);
    }
  }

  /** Browser-preview only: stash the artifact's HTML so the webHost mock's
   *  `read_file_bytes_base64` can serve it back to WorkbookView. */
  register(path: string, html: string): void {
    this.#bytes.set(path, html);
  }

  /** Bump a path's reload counter so an already-open tab re-reads the
   *  artifact's bytes. Called when an `updated` artifact event lands (the
   *  agent re-wrote the same component). Works for both the browser mock
   *  and the packaged app (where the runtime wrote new bytes to disk). */
  markUpdated(path: string): void {
    this.revisions = {
      ...this.revisions,
      [path]: (this.revisions[path] ?? 0) + 1,
    };
  }

  /** Browser-preview only: read previously-registered artifact bytes. */
  read(path: string): string | undefined {
    return this.#bytes.get(path);
  }

  /** Reset the per-run opened set (a new chat clears it). */
  reset(): void {
    this.#opened.clear();
  }
}

export const componentArtifacts = new ComponentArtifacts();

// Expose the byte registry to the webHost mock without an import cycle
// (webHost is browser-only glue installed before the app boots). The mock
// reads `window.__WB_ARTIFACTS__` to serve registered artifact bytes.
if (typeof window !== "undefined") {
  (window as unknown as { __WB_ARTIFACTS__?: ComponentArtifacts }).__WB_ARTIFACTS__ =
    componentArtifacts;
}
