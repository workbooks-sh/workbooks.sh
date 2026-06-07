// Engine sessions client — reusable surface for any UI that needs to
// list, filter, or refresh the engine's session ledger. The engine's
// /api/sessions endpoint is the source of truth: every session the
// engine ever started lives there (capped to a retention window by
// SessionTrack), regardless of who started it — chat tab, board
// coordinator, CLI, wizard, etc.
//
// This module deliberately lives outside $lib/chat/ and $lib/board/
// because the modal that consumes it is meant to be reusable across
// surfaces (chat header today; potentially board panel, settings
// view, status tray later). Keeping the client neutral here avoids
// pulling chat or board imports into surfaces that don't need them.

import { engineRequest, enginePath } from "$lib/engine-api/gen";

export type SessionStatus = "running" | "completed" | "failed" | "cancelled";

/** One session row as returned by /api/sessions. Matches
 *  Workbooks.Engine.SessionTrack.snapshot/0's serialized shape. */
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

/** Fetch the session list from the engine. Returns [] when the sidecar
 *  isn't reachable or the response is malformed — the calling UI
 *  renders an empty state in both cases, which is the right user
 *  experience either way. Hard 3s timeout so a hung daemon never
 *  leaves the UI stuck on "Loading…". */
export async function listSessions(
  opts: ListSessionsOptions = {},
): Promise<SessionRow[]> {
  try {
    const body = await engineRequest<{ sessions?: SessionRow[] }>(
      enginePath.sessions_list,
      { query: opts.activeOnly ? "?active=true" : "", timeoutMs: 3_000 },
    );
    return Array.isArray(body?.sessions) ? body.sessions : [];
  } catch {
    // Engine down, timeout, or malformed body — the UI's empty state
    // is the right signal in every case.
    return [];
  }
}
