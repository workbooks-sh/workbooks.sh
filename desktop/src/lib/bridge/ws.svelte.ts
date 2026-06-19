// Local event store for the desktop bridge.
//
// Phoenix is gone (transport cutover complete). Chat runs through
// `rcp.request("/api/run")` with synthetic events; the browser-preview
// mock agent (webHost → runMockComponentAgent) is the only event source,
// pushing frames through `emitLocal()`. This store is the reactive sink
// the chat surface and the GeneralSettings dev log subscribe to.

export interface BridgeEvent {
  // Event name (e.g. "session_started", "llm_turn_start"). Bridge-level
  // synthetic events use "bridge:*" names.
  name: string;
  payload: unknown;
  topic: string;
  /** Originating session id when the frame carries one, else null. */
  sessionId: string | null;
  /** Wall-clock from the envelope when present, else receive time. */
  ts: number;
  receivedAt: number;
}

type Handler = (e: BridgeEvent) => void;

interface PartialEvent {
  name: string;
  payload: unknown;
  topic: string;
  sessionId?: string | null;
  ts?: number;
}

// wb-i38o.12 — workbook-as-memory result shapes. Consumed by the REST
// surface in `memory_sources.svelte.ts` (/api/memory/sources).
export interface AddWorkbookResult {
  workbook_path: string;
  file_count: number;
  indexed_count: number;
}

export interface RemoveWorkbookResult {
  file_count: number;
  entry_count: number;
}

export interface ListWorkbooksResult {
  workbooks: string[];
}

class WsBridgeStore {
  events = $state<BridgeEvent[]>([]);
  count = $state(0);
  lastError = $state<string | null>(null);

  #handlers = new Set<Handler>();

  /** No transport to set up anymore — Phoenix is gone. Kept so existing
   *  callers (GeneralSettings, +page) stay valid; it's a no-op. */
  init() {}

  destroy() {
    this.#handlers.clear();
  }

  subscribe(h: Handler): () => void {
    this.#handlers.add(h);
    return () => this.#handlers.delete(h);
  }

  /** Inject a synthetic bridge event into the local handler set. Used by
   *  the browser-preview mock agent (webHost) to drive the chat surface.
   *  Mirrors the runtime's per-session telemetry shape. */
  emitLocal(name: string, payload: unknown, topic: string): void {
    this.#emit({ name, payload, topic });
  }

  #emit(partial: PartialEvent) {
    const now = Date.now();
    const e: BridgeEvent = {
      name: partial.name,
      payload: partial.payload,
      topic: partial.topic,
      sessionId: partial.sessionId ?? null,
      ts: partial.ts ?? now,
      receivedAt: now,
    };
    this.count += 1;
    // Bounded ring — keep the most recent 200 events.
    if (this.events.length >= 200) this.events = this.events.slice(-199);
    this.events = [...this.events, e];
    for (const h of this.#handlers) h(e);
  }
}

export const ws = new WsBridgeStore();
