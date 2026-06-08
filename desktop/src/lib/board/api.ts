// Board data layer — RUNTIME control-plane client (graceful-offline).
//
// "Boards are now workflows": the board reads matches from the org-ql
// surface on the optional Elixir tier (POST /api/oql/query) and groups
// them into columns. All engine failures normalize to a `BoardApiError`
// (alias of EngineApiError) so the panel renders one consistent UI.
//
// Offline behavior: the read paths (runQuery, listBoardViews) degrade to
// empty results when the daemon is down (EngineApiError code
// "daemon_down") so the board shows an empty state rather than throwing
// to the UI. The write paths (patchHeadline, setBoardState) intentionally
// surface their error — a failed mutation must be visible to the user.

import { EngineApiError, engineRequest } from "$lib/engine-api/gen";
import { listSessions, type SessionRow } from "$lib/sessions/api";
import type {
  BoardCardItem,
  BoardColumn,
  BoardHeadline,
  QueryResponse,
} from "./types";
import { CANONICAL_COLUMNS } from "./types";

// One engine error class, generated from the verb schema. The old
// bespoke BoardApiError is the same shape; the alias keeps call sites
// stable while there is exactly one class at runtime.
export { EngineApiError as BoardApiError };

/** True when the failure is the daemon being unreachable (offline or
 *  not yet booted). Both the legacy "sidecar_down" and the canonical
 *  "daemon_down" codes are treated as offline so this keeps working
 *  across the engine-api rename. */
function isDaemonDown(e: unknown): boolean {
  return (
    e instanceof EngineApiError &&
    (e.code === "daemon_down" || e.code === "sidecar_down")
  );
}

/** Live sessions for the assigned column — the session type and client
 *  live in $lib/sessions/api; re-exported so board consumers keep one
 *  import surface. listSessions already degrades to [] when offline. */
export type LiveSession = SessionRow;
export async function listActiveSessions(): Promise<LiveSession[]> {
  return listSessions({ activeOnly: true });
}

/** Run an org-ql query against `path`, returning the matched headlines.
 *  The S-expression is sent verbatim in the request body; parse errors
 *  surface as `BoardApiError("parse_error", ...)` with the Q-code in the
 *  message. */
export async function runQuery(
  path: string,
  sexpr: string,
): Promise<QueryResponse> {
  let parsed: QueryResponse;
  try {
    parsed = await engineRequest<QueryResponse>("/api/oql/query", {
      query: `?path=${encodeURIComponent(path)}`,
      bodyText: sexpr,
      contentType: "text/x-oql-sexpr",
    });
  } catch (e) {
    // Offline → empty board, never throw to the UI. Real query/parse
    // errors (parse_error etc.) still propagate so the panel can show
    // the Q-code.
    if (isDaemonDown(e)) return { headlines: [], parse_warnings: [] };
    throw e;
  }
  // Defensive — the server should always return an array, but a
  // misbehaving proxy could mangle it.
  if (!Array.isArray(parsed?.headlines)) {
    throw new EngineApiError(
      "bad_response",
      "Response was missing the `headlines` array.",
      200,
    );
  }
  return parsed;
}

/** wb-alkb — PATCH a headline by ID. The body shape mirrors the
 *  controller spec: { path, op, ...args } where args depend on op
 *  (state, name+value, or entry). Errors normalize to BoardApiError
 *  matching the runQuery surface. */
export async function patchHeadline(
  path: string,
  id: string,
  op: "transition_todo" | "set_property" | "append_logbook",
  args:
    | { state: string }
    | { name: string; value: string }
    | { entry: string },
): Promise<void> {
  await engineRequest(`/api/oql/headline/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: { path, op, ...args },
  });
}

/** One agent-managed board view from kanban-views.org. */
export interface BoardView {
  id: string;
  name: string;
  path: string;
  query: string;
  /** Optional `:ICON:` value — `emoji:🎯` / `lucide:Target` /
   *  `hidden` / `null` → fall back to initials. Rendered via the
   *  shared AgentIcon component. */
  icon?: string | null;
  /** Optional `:DESCRIPTION:` value — used as the muted tagline
   *  under the board's name in the picker dropdown. */
  tagline?: string | null;
  /** Optional `:ACTION_LABEL:` value — overrides the default
   *  "New task" button label on the board toolbar. */
  action_label?: string | null;
  /** Optional `:GROUP_BY:` value — `status` (default) | `assigned`
   *  | `priority` | `tag` | `<PROPERTY>`. Determines what each
   *  column represents on the rendered board. */
  group_by?: string | null;
  /** Optional `:COLUMNS:` override — whitespace- or comma-separated
   *  list of column values to pin. Use to surface empty columns or
   *  to enforce an order independent of the query's results. */
  columns?: string | null;

  // ── wb-n21i — orchestration properties (all optional). A board
  // with no :ORCHESTRATOR: stays manual-only; the BoardCoordinator
  // skips it. ──
  /** Agent slug driving dispatch, or "none" / null for manual. */
  orchestrator?: string | null;
  /** sequential | parallel | round-robin. Default: sequential. */
  dispatch_mode?: string | null;
  /** none | orchestrator | human | review-after. Default: none. */
  approval_policy?: string | null;
  /** Cap on concurrent in-flight sessions from this board. */
  max_concurrent?: number | null;

  // ── Board lifecycle state (user-extensible play/pause + custom). ──
  /** Space-separated list of valid lifecycle states. User-editable.
   *  Default when absent: `paused running`. */
  states?: string | null;
  /** Current lifecycle state. Must be a value in `states`. Default
   *  when absent: first value in `states` (typically `paused`). */
  state?: string | null;
  /** Space-separated list of states during which the coordinator
   *  may dispatch. Default when absent: `running`. */
  dispatch_when?: string | null;
}

/** Parse a board's :STATES: value into an array. Falls back to the
 *  default 2-state vocabulary. */
export function boardStates(view: BoardView): string[] {
  const raw = (view.states ?? "").trim();
  if (!raw) return ["paused", "running"];
  return raw.split(/\s+/).filter(Boolean);
}

/** Current state with fallback to the first declared state (paused
 *  by default). */
export function boardState(view: BoardView): string {
  const s = (view.state ?? "").trim();
  if (s) return s;
  return boardStates(view)[0] ?? "paused";
}

/** States during which dispatch is allowed. Default `running`. */
export function boardDispatchWhen(view: BoardView): string[] {
  const raw = (view.dispatch_when ?? "").trim();
  if (!raw) return ["running"];
  return raw.split(/\s+/).filter(Boolean);
}

/** Set the board's current state via the oql HTTP write surface.
 *  Mutates `kanban-views.org` at the board's headline ID. The
 *  sidecar broadcasts `oql:document:<path>` on success; the
 *  BoardCoordinator listens and re-ticks. */
export async function setBoardState(
  viewsPath: string,
  boardId: string,
  nextState: string,
): Promise<void> {
  await engineRequest(`/api/oql/headline/${encodeURIComponent(boardId)}`, {
    method: "PATCH",
    body: { path: viewsPath, op: "set_property", key: "STATE", value: nextState },
  });
}

/** wb-uatn — fetch the named board views from a `kanban-views.org`
 *  file. Returns an empty array if the file doesn't exist (the panel
 *  falls back to its hardcoded default). Throws BoardApiError on any
 *  non-2xx response. */
export async function listBoardViews(path: string): Promise<BoardView[]> {
  let body: BoardView[];
  try {
    body = await engineRequest<BoardView[]>("/api/oql/board-views", {
      query: `?path=${encodeURIComponent(path)}`,
    });
  } catch (e) {
    // Offline → no views; the panel falls back to its hardcoded
    // default board. Never throw to the UI for daemon-down.
    if (isDaemonDown(e)) return [];
    throw e;
  }
  if (!Array.isArray(body)) {
    throw new EngineApiError(
      "bad_response",
      "Server returned a non-array body for /api/oql/board-views.",
      200,
    );
  }
  return body;
}

/** Group matched headlines into columns by their TODO keyword.
 *
 *  Order: canonical GTD order, filtered to states that actually appear.
 *  Headlines without a TODO keyword skip the board (defensive — the
 *  caller's query should filter them out, but if the user picks a
 *  loose query like `(property ID)` against a heterogeneous file,
 *  we'd rather drop the no-state rows than show a confusing column). */
export function groupByStatus(
  headlines: BoardHeadline[],
  starterColumns: readonly string[] = [],
): BoardColumn[] {
  const buckets = new Map<string, BoardCardItem[]>();
  for (const col of starterColumns) {
    buckets.set(col, []);
  }
  headlines.forEach((h, i) => {
    if (!h.state) return;
    const cardId = h.id ?? `_synth_${i}_${h.title}`;
    const card: BoardCardItem = { ...h, cardId };
    const arr = buckets.get(h.state) ?? [];
    arr.push(card);
    buckets.set(h.state, arr);
  });
  // Canonical first, alpha-sorted extras after.
  const order: string[] = [];
  for (const c of CANONICAL_COLUMNS) {
    if (buckets.has(c)) order.push(c);
  }
  const extras = [...buckets.keys()]
    .filter((c) => !CANONICAL_COLUMNS.includes(c))
    .sort();
  order.push(...extras);
  return order.map((state) => ({ state, cards: buckets.get(state) ?? [] }));
}

/** Generic grouping driver. Picks the per-card key based on `kind`
 *  and renders columns in a stable order.
 *
 *  - `status`   — TODO keyword. Canonical GTD column order.
 *  - `assigned` — `:ASSIGNED_AGENT:` property. Columns are the
 *                 observed agents (or pinned via `pinnedColumns`).
 *                 Falls into a special "(unassigned)" bucket when
 *                 the property is absent.
 *  - `priority` — `A` / `B` / `C` cookie.
 *  - `tag`      — first observed tag. Multi-tag headlines bucket
 *                 only into the first tag.
 *  - anything else — treats `kind` as the property key.
 *
 *  `pinnedColumns` is the optional list of columns to surface even
 *  when empty (used for "show every agent" semantics). Order is
 *  preserved as given; observed-but-not-pinned columns append after,
 *  alpha-sorted. */
export function groupBy(
  headlines: BoardHeadline[],
  kind: string,
  pinnedColumns: readonly string[] = [],
): BoardColumn[] {
  const normalized = (kind || "status").trim();
  if (normalized === "status") {
    return groupByStatus(headlines, pinnedColumns);
  }

  const buckets = new Map<string, BoardCardItem[]>();
  for (const col of pinnedColumns) {
    buckets.set(col, []);
  }

  const keyFor = (h: BoardHeadline): string | null => {
    switch (normalized) {
      case "assigned":
        // Read :ASSIGNED_AGENT: from a future BoardHeadline.properties
        // field; for now derive from the synthetic field on the
        // wire shape (the oql query JSON emits it under `assigned`
        // when the wire layer adds it — until then, fall back to
        // the "(unassigned)" bucket so the board still renders).
        return (
          (h as BoardHeadline & { assigned?: string | null }).assigned ??
          "(unassigned)"
        );
      case "priority":
        return h.priority ?? "(none)";
      case "tag":
        return h.tags[0] ?? "(untagged)";
      default:
        // Property fallback — also reads from the wire's
        // `properties: { KEY: value }` once we surface it.
        const props =
          (h as BoardHeadline & { properties?: Record<string, string> })
            .properties ?? {};
        return props[normalized.toUpperCase()] ?? null;
    }
  };

  headlines.forEach((h, i) => {
    const key = keyFor(h);
    if (!key) return;
    const cardId = h.id ?? `_synth_${i}_${h.title}`;
    const card: BoardCardItem = { ...h, cardId };
    const arr = buckets.get(key) ?? [];
    arr.push(card);
    buckets.set(key, arr);
  });

  // Pinned columns first (in given order), then alpha-sorted extras.
  const order: string[] = [];
  for (const c of pinnedColumns) {
    if (buckets.has(c)) order.push(c);
  }
  const extras = [...buckets.keys()]
    .filter((c) => !pinnedColumns.includes(c))
    .sort();
  order.push(...extras);
  return order.map((state) => ({ state, cards: buckets.get(state) ?? [] }));
}
