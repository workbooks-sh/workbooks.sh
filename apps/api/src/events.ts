import type { EventInsert, EventRow } from '@brandnana/schema/events';

export async function recordEvent(db: D1Database, event: EventInsert): Promise<void> {
  await db.prepare(
    `INSERT INTO events (id, ts, account_id, verb_id, source, duration_ms, status,
       error_code, error_message, vendor_calls, vendor_cost_usd,
       request_payload_hash, response_payload_hash)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    event.id, event.ts, event.account_id, event.verb_id, event.source,
    event.duration_ms, event.status,
    event.error_code ?? null,
    event.error_message ?? null,
    event.vendor_calls ? JSON.stringify(event.vendor_calls) : null,
    event.vendor_cost_usd,
    event.request_payload_hash ?? null,
    event.response_payload_hash ?? null,
  ).run();
}

export async function queryEvents(db: D1Database, opts: {
  account_id?: string;
  verb_id?: string;
  from_ts?: number;
  to_ts?: number;
  status?: 'ok' | 'error';
  limit?: number;
  cursor?: string;          // base64-encoded ts of last row
}): Promise<{ items: EventRow[]; next_cursor?: string }> {
  const limit = Math.min(opts.limit ?? 50, 200);
  const conditions: string[] = [];
  const bindings: (string | number)[] = [];

  if (opts.account_id) {
    conditions.push('account_id = ?');
    bindings.push(opts.account_id);
  }
  if (opts.verb_id) {
    conditions.push('verb_id = ?');
    bindings.push(opts.verb_id);
  }
  if (opts.status) {
    conditions.push('status = ?');
    bindings.push(opts.status);
  }
  if (opts.from_ts !== undefined) {
    conditions.push('ts >= ?');
    bindings.push(opts.from_ts);
  }
  if (opts.to_ts !== undefined) {
    conditions.push('ts <= ?');
    bindings.push(opts.to_ts);
  }
  if (opts.cursor) {
    // cursor = base64-encoded ts of last row; paginate backwards (DESC)
    const cursorTs = Number(atob(opts.cursor));
    if (!Number.isNaN(cursorTs)) {
      conditions.push('ts < ?');
      bindings.push(cursorTs);
    }
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const sql = `SELECT * FROM events ${where} ORDER BY ts DESC LIMIT ?`;
  bindings.push(limit + 1); // fetch one extra to detect next page

  const result = await db.prepare(sql).bind(...bindings).all<EventRow>();
  const rows = result.results ?? [];

  let next_cursor: string | undefined;
  if (rows.length > limit) {
    rows.pop();
    const lastTs = rows[rows.length - 1]?.ts;
    if (lastTs !== undefined) {
      next_cursor = btoa(String(lastTs));
    }
  }

  // Parse vendor_calls JSON back from the DB TEXT column
  const items = rows.map((row) => ({
    ...row,
    vendor_calls: row.vendor_calls
      ? (JSON.parse(row.vendor_calls as unknown as string) as EventRow['vendor_calls'])
      : null,
  }));

  return { items, next_cursor };
}
