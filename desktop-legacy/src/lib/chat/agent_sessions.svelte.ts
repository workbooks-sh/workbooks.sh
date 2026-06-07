// Per-agent session history — client-side log persisted to localStorage.
//
// v1 stand-in for the server-backed history (wb-shtl.4). The backend's
// Postgres `sessions` table already stores `agent_slug` per row, so the
// resumable / cross-device version slots in cleanly when wb-nlln.27 +
// the WS document broadcast (wb-i38o.33.3) land. Until then: localStorage
// keyed by agent slug, capped per-agent so a chatty workspace doesn't
// run away with quota.
//
// Hooks into the chat lifecycle:
//   - `record(slug, sessionId, prompt)` — call on `chatSession.send()`
//     after the session id is returned. Appends a "pending" entry.
//   - `updateStatus(sessionId, status, detail?)` — call from
//     `chatSession.#reproject()` whenever the session's status
//     transitions to a terminal value (completed / failed / cancelled).

const STORAGE_PREFIX = "wb.agent-sessions.";
const MAX_PER_AGENT = 50;

export type SessionLogStatus =
  | "pending"
  | "running"
  | "completed"
  | "failed"
  | "cancelled";

export interface SessionLogEntry {
  /** Sidecar-assigned session uuid. */
  id: string;
  /** Agent slug at the time of send — pinned because the user may
   *  switch agents mid-history. */
  slug: string;
  /** The prompt that started the session (verbatim, truncated for
   *  display by the explorer). */
  prompt: string;
  status: SessionLogStatus;
  /** Wall-clock millis since epoch. */
  startedAt: number;
  finishedAt: number | null;
  /** Human-readable detail surfaced on terminal-state entries (e.g.
   *  the reason a session failed). */
  detail: string | null;
}

class AgentSessionsStore {
  /** All logs, keyed by agent slug. $state so the SessionExplorer
   *  re-renders as new entries land. */
  logs = $state<Record<string, SessionLogEntry[]>>({});

  #loaded = false;

  /** Hydrate from localStorage once on first access. Lazy to avoid
   *  doing work for renderers that never open the explorer. */
  ensureLoaded(): void {
    if (this.#loaded) return;
    this.#loaded = true;
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (!k || !k.startsWith(STORAGE_PREFIX)) continue;
        const slug = k.slice(STORAGE_PREFIX.length);
        const raw = localStorage.getItem(k);
        if (!raw) continue;
        try {
          const parsed = JSON.parse(raw) as SessionLogEntry[];
          if (Array.isArray(parsed)) this.logs[slug] = parsed;
        } catch {
          // Malformed entry — drop it rather than crash. The user
          // loses one slug's history at worst.
        }
      }
    } catch {
      // localStorage may be unavailable. The store still works in
      // memory for the current session.
    }
  }

  /** Append a new pending entry for an outbound prompt. */
  record(slug: string, sessionId: string, prompt: string): void {
    this.ensureLoaded();
    const entry: SessionLogEntry = {
      id: sessionId,
      slug,
      prompt,
      status: "pending",
      startedAt: Date.now(),
      finishedAt: null,
      detail: null,
    };
    const existing = this.logs[slug] ?? [];
    // Cap per-agent. Drop oldest entries first.
    const next = [...existing, entry].slice(-MAX_PER_AGENT);
    this.logs[slug] = next;
    this.#persist(slug);
  }

  /** Update the entry matching `sessionId`. Searches across slugs
   *  since the explorer doesn't know which slug owns a given id. */
  updateStatus(
    sessionId: string,
    status: SessionLogStatus,
    detail: string | null = null,
  ): void {
    this.ensureLoaded();
    for (const slug of Object.keys(this.logs)) {
      const list = this.logs[slug];
      const idx = list.findIndex((e) => e.id === sessionId);
      if (idx < 0) continue;
      const finished =
        status === "completed" || status === "failed" || status === "cancelled";
      const updated: SessionLogEntry = {
        ...list[idx],
        status,
        detail: detail ?? list[idx].detail,
        finishedAt: finished ? Date.now() : list[idx].finishedAt,
      };
      this.logs[slug] = [
        ...list.slice(0, idx),
        updated,
        ...list.slice(idx + 1),
      ];
      this.#persist(slug);
      return;
    }
  }

  /** Newest-first slice for an agent. */
  forAgent(slug: string): SessionLogEntry[] {
    this.ensureLoaded();
    const list = this.logs[slug] ?? [];
    return [...list].reverse();
  }

  /** Clear the log for a given agent. Used when the user deletes the
   *  agent in Settings — keeps localStorage from accumulating dead
   *  per-slug keys. */
  clearAgent(slug: string): void {
    this.ensureLoaded();
    delete this.logs[slug];
    try {
      localStorage.removeItem(STORAGE_PREFIX + slug);
    } catch {
      // Best-effort.
    }
  }

  #persist(slug: string): void {
    try {
      const list = this.logs[slug];
      if (!list || list.length === 0) {
        localStorage.removeItem(STORAGE_PREFIX + slug);
        return;
      }
      localStorage.setItem(STORAGE_PREFIX + slug, JSON.stringify(list));
    } catch {
      // Quota exceeded or unavailable — keep in-memory state going.
    }
  }
}

export const agentSessions = new AgentSessionsStore();
