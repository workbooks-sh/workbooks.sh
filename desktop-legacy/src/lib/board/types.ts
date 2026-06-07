// wb-i38o.33.6 — types for the Kanban board.
//
// Mirrors the JSON shape returned by `POST /api/oql/query`, which is
// itself the shape `oql-cli`'s `--format=json` output emits.

/** One matched headline as the agent server returns it. */
export interface BoardHeadline {
  /** :ID: property, if set. */
  id: string | null;
  /** Headline title without the TODO keyword / priority / tags. */
  title: string;
  /** TODO keyword (TODO, DOING, DONE, …) or null when none. */
  state: string | null;
  /** Priority letter (A/B/C) or null. */
  priority: string | null;
  /** 1-based outline level. */
  level: number;
  /** Tags attached to the headline. */
  tags: string[];
  /** :ASSIGNED_AGENT: property value, surfaced as a top-level
   *  field for kanban group-by=assigned (wb-8fcg). Mirrors what's
   *  in `properties.ASSIGNED_AGENT` — convenience, not a new fact. */
  assigned?: string | null;
  /** Full :PROPERTIES: drawer snapshot, keyed by uppercase property
   *  name. Used by kanban group-by=<PROPERTY> for arbitrary
   *  groupings the runtime doesn't pre-surface. */
  properties?: Record<string, string>;
}

/** Wire shape of the /api/oql/query 200 response. */
export interface QueryResponse {
  headlines: BoardHeadline[];
  parse_warnings: string[];
}

/** Wire shape of the 4xx/5xx error response. */
export interface QueryErrorResponse {
  error: string;
  message: string;
}

/** A board card — a BoardHeadline plus a guaranteed-stable string id
 *  for svelte-dnd-action's item tracking. `cardId` equals
 *  `BoardHeadline.id` when set; otherwise it's a synthetic value
 *  derived from the title + position so DnD events still have a
 *  unique key. (svelte-dnd-action requires non-null string ids.) */
export interface BoardCardItem extends BoardHeadline {
  cardId: string;
  /** wb-rgon — set when the card is backed by a live session
   *  rather than an on-disk headline. The card renders with a
   *  "running" badge and skips the DnD writeback. */
  live?: {
    sessionId: string;
    startedAt: number;
  };
}

/** One rendered column on the board: header + the cards in it. */
export interface BoardColumn {
  /** Status keyword the column represents (TODO, DOING, etc.). */
  state: string;
  /** Headlines that fall in this column, in original document order. */
  cards: BoardCardItem[];
}

/** GTD canonical column order. Columns absent from the matched set drop
 *  out unless the user pins them via the (future) `:columns` override. */
export const CANONICAL_COLUMNS: readonly string[] = Object.freeze([
  "TODO",
  "NEXT",
  "WAITING",
  "DOING",
  "BLOCKED",
  "SOMEDAY",
  "DONE",
  "CANCELED",
  "FAILED",
  "ABANDONED",
]);

/** A column that exists even with zero cards — useful for empty-state UX
 *  when the board first lands on a fresh plan.org. */
export const STARTER_COLUMNS: readonly string[] = Object.freeze([
  "TODO",
  "DOING",
  "DONE",
]);
