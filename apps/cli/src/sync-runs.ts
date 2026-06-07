// Audit-log helper for sync_runs.
//
// Every data-touching command (catalog crawl, brand fetch, ads search,
// ads sync) wraps its core work with `withSyncRun(db, info, fn)`. We
// insert a row at start, run the work, then update with ok=1 or
// ok=0+error so a stale local SQLite can be inspected with:
//
//   SELECT * FROM sync_runs ORDER BY started_at DESC LIMIT 20;

import { randomUUID } from "node:crypto";
import type { DbLike } from "./sqlite.js";

export interface SyncRunInfo {
  kind: "ads" | "catalog" | "brand";
  source: string;
  brand_id?: string | null;
}

export async function withSyncRun<T>(
  db: DbLike,
  info: SyncRunInfo,
  fn: () => Promise<T>,
): Promise<T> {
  const id = randomUUID();
  const started = Date.now();
  db.prepare(
    `INSERT INTO sync_runs (id, kind, source, brand_id, started_at, ok)
     VALUES (?, ?, ?, ?, ?, 0)`,
  ).run(id, info.kind, info.source, info.brand_id ?? null, started);

  try {
    const result = await fn();
    db.prepare("UPDATE sync_runs SET finished_at = ?, ok = 1, error = NULL WHERE id = ?").run(
      Date.now(),
      id,
    );
    return result;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    db.prepare("UPDATE sync_runs SET finished_at = ?, ok = 0, error = ? WHERE id = ?").run(
      Date.now(),
      msg,
      id,
    );
    throw err;
  }
}
