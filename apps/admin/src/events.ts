// Event log query — paginated read of the events table.
//
// GET /events query params:
//   verb?    — filter by verb_id (exact match)
//   from?    — start timestamp (ms)
//   to?      — end timestamp (ms)
//   limit?   — max rows per page (default 100, max 500)
//   cursor?  — opaque pagination cursor (base64-encoded last ts + id)
//
// Returns: { items: EventRow[], next_cursor? }
// The next_cursor is present only when more rows exist beyond the current page.
// vendor_calls is returned as a parsed array (JSON decoded from the DB string).

import { Hono } from 'hono';
import type { EventRow } from '@brandnana/schema';
import type { Bindings } from './env.js';

const MAX_LIMIT = 500;
const DEFAULT_LIMIT = 100;

// Cursor encodes { ts, id } so we can do keyset pagination on (ts DESC, id ASC).
interface Cursor {
  ts: number;
  id: string;
}

function encodeCursor(ts: number, id: string): string {
  return btoa(JSON.stringify({ ts, id }));
}

function decodeCursor(raw: string): Cursor | null {
  try {
    const parsed = JSON.parse(atob(raw)) as unknown;
    if (
      typeof parsed === 'object' &&
      parsed !== null &&
      'ts' in parsed &&
      'id' in parsed &&
      typeof (parsed as Record<string, unknown>)['ts'] === 'number' &&
      typeof (parsed as Record<string, unknown>)['id'] === 'string'
    ) {
      return parsed as Cursor;
    }
    return null;
  } catch {
    return null;
  }
}

// Raw DB row — vendor_calls is stored as a JSON string in SQLite.
interface EventDbRow extends Omit<EventRow, 'vendor_calls'> {
  vendor_calls: string | null;
}

const app = new Hono<{ Bindings: Bindings }>();

app.get('/', async (c) => {
  const verbParam = c.req.query('verb');
  const fromParam = c.req.query('from');
  const toParam = c.req.query('to');
  const limitParam = c.req.query('limit');
  const cursorParam = c.req.query('cursor');

  const limit = Math.min(
    limitParam != null ? Math.max(1, Number(limitParam)) : DEFAULT_LIMIT,
    MAX_LIMIT,
  );

  if (isNaN(limit)) return c.json({ error: 'limit must be a number' }, 400);

  const conditions: string[] = [];
  const binds: unknown[] = [];

  if (fromParam != null) {
    const from = Number(fromParam);
    if (isNaN(from)) return c.json({ error: 'from must be a numeric timestamp (ms)' }, 400);
    conditions.push('ts >= ?');
    binds.push(from);
  }

  if (toParam != null) {
    const to = Number(toParam);
    if (isNaN(to)) return c.json({ error: 'to must be a numeric timestamp (ms)' }, 400);
    conditions.push('ts < ?');
    binds.push(to);
  }

  if (verbParam != null) {
    conditions.push('verb_id = ?');
    binds.push(verbParam);
  }

  // Keyset pagination: cursor encodes the last (ts, id) from the previous page.
  // Fetch rows where ts < cursor.ts OR (ts = cursor.ts AND id > cursor.id).
  if (cursorParam != null) {
    const cursor = decodeCursor(cursorParam);
    if (!cursor) return c.json({ error: 'invalid cursor' }, 400);
    conditions.push('(ts < ? OR (ts = ? AND id > ?))');
    binds.push(cursor.ts, cursor.ts, cursor.id);
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  // Fetch limit+1 to detect if there's a next page.
  const sql = `SELECT * FROM events ${where} ORDER BY ts DESC, id ASC LIMIT ?`;
  binds.push(limit + 1);

  const { results } = await c.env.DB.prepare(sql).bind(...binds).all<EventDbRow>();
  const rows = results ?? [];

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;

  // Parse vendor_calls JSON string → array.
  const items: EventRow[] = page.map((r) => ({
    ...r,
    vendor_calls: r.vendor_calls != null ? (JSON.parse(r.vendor_calls) as EventRow['vendor_calls']) : null,
  }));

  const lastRow = page[page.length - 1];
  const next_cursor =
    hasMore && lastRow != null ? encodeCursor(lastRow.ts, lastRow.id) : undefined;

  return c.json({ items, ...(next_cursor != null ? { next_cursor } : {}) });
});

export default app;
