// Waldo session history — persisted transcripts so the panel can browse and
// reopen past conversations. The runtime ledger (/api/sessions) tracks session
// METADATA cross-surface; this keeps the actual rendered lines locally so a
// past conversation can be read back in-panel without a server round-trip.
//
// localStorage, newest-first, capped so a chatty workspace can't run away with
// quota. One entry per finished session.

const STORAGE_KEY = "wb.waldo.history";
const MAX = 60;

export interface SavedLine {
  who: "you" | "waldo";
  text: string;
  kind: string; // "msg" | "tool" | "status"
}

export interface SavedSession {
  id: string;
  agent: string;
  /** First user line, for the list. */
  title: string;
  ts: number;
  lines: SavedLine[];
}

class SessionHistoryStore {
  sessions = $state<SavedSession[]>([]);
  #loaded = false;

  ensureLoaded(): void {
    if (this.#loaded) return;
    this.#loaded = true;
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw) as SavedSession[];
        if (Array.isArray(parsed)) this.sessions = parsed;
      }
    } catch {
      /* localStorage unavailable — stay in-memory */
    }
  }

  /** Upsert a finished session's transcript (newest-first, capped). */
  save(session: SavedSession): void {
    this.ensureLoaded();
    if (!session.id || session.lines.length === 0) return;
    const without = this.sessions.filter((s) => s.id !== session.id);
    this.sessions = [session, ...without].slice(0, MAX);
    this.#persist();
  }

  get(id: string): SavedSession | null {
    this.ensureLoaded();
    return this.sessions.find((s) => s.id === id) ?? null;
  }

  remove(id: string): void {
    this.ensureLoaded();
    this.sessions = this.sessions.filter((s) => s.id !== id);
    this.#persist();
  }

  clear(): void {
    this.sessions = [];
    this.#persist();
  }

  #persist(): void {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.sessions));
    } catch {
      /* quota / unavailable — keep in-memory */
    }
  }
}

export const sessionHistory = new SessionHistoryStore();
