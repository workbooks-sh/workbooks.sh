// Sessions ledger client — runtime control-plane surface for any UI
// that needs to list, filter, or refresh the agent session ledger.
//
// RUNTIME cap (graceful-offline): GET /api/sessions on the optional
// Elixir tier is the source of truth — every agent session the runtime
// ever started lives there (capped to a retention window), regardless
// of who started it: chat tab, board coordinator, CLI, wizard, etc.
//
// This module deliberately lives outside $lib/chat/ and $lib/board/
// because the modal that consumes it is meant to be reusable across
// surfaces (chat header today; potentially board panel, settings
// view, status tray later). Keeping the client neutral here avoids
// pulling chat or board imports into surfaces that don't need them.
//
// Schema note: runtime Workbooks.Sessions is workbook-INSTANCE VFS
// resume, NOT the agent ledger — the ledger route (GET /api/sessions)
// is still pending on the runtime. Until it lands, every call here
// degrades to an empty ledger, which is the correct empty-state UX.

import { engineRequest } from "$lib/engine-api/gen";

export type SessionStatus = "running" | "completed" | "failed" | "cancelled";

/** One session row as returned by GET /api/sessions. */
export interface SessionRow {
  session_id: string;
  agent_slug: string | null;
  prompt_preview: string | null;
  workdir: string | null;
  status: SessionStatus;
  started_at: string | null;
  finished_at: string | null;
}

export interface ListSessionsOptions {
  /** When true, narrow to status=running. Default false (all states). */
  activeOnly?: boolean;
}

/** Fetch the session ledger from the runtime. Returns [] when the
 *  daemon isn't reachable (offline), the route is absent (pending),
 *  the request times out, or the response is malformed — the calling
 *  UI renders an empty state in every case, which is the right user
 *  experience either way. Hard 3s timeout so a hung daemon never
 *  leaves the UI stuck on "Loading…". */
export async function listSessions(
  opts: ListSessionsOptions = {},
): Promise<SessionRow[]> {
  try {
    const body = await engineRequest<{ sessions?: SessionRow[] }>(
      "/api/sessions",
      { query: opts.activeOnly ? "?active=true" : "", timeoutMs: 3_000 },
    );
    return Array.isArray(body?.sessions) ? body.sessions : [];
  } catch {
    // Daemon down, route pending, timeout, or malformed body — the
    // UI's empty state is the right signal in every case.
    return [];
  }
}
