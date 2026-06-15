// workponents · data — the browser-local SQLite tier (sqlite-wasm).
//
// Real SQLite, in the page: the full dialect, byte-compatible with the runtime's
// native `exqlite` VFS. This is "the SQLite layer in the workbook itself" for the
// static / no-runtime case — and, ahead, the engine that opens a workbook's
// hydrated embedded VFS (the single-HTML format). ~1MB, lazily loaded once.
//
// Override the asset base via `window.__WB_SQLITE_WASM__` (a base URL ending in
// `/`) to self-host instead of the CDN — e.g. ship the wasm with the workbook.
import { inferType } from "./contract.js";

const DEFAULT_BASE = "https://cdn.jsdelivr.net/npm/@sqlite.org/sqlite-wasm@3.50.1-build1/";
let _boot = null;

/** Boot sqlite-wasm once (idempotent). Resolves { sqlite3, db } (in-memory db). */
export function bootSqlite() {
  if (_boot) return _boot;
  _boot = (async () => {
    if (typeof window === "undefined") throw new Error("sqlite-wasm needs a browser");
    const base = window.__WB_SQLITE_WASM__ || DEFAULT_BASE;
    const mod = await import(/* @vite-ignore */ base + "index.mjs");
    const sqlite3 = await mod.default({ locateFile: (f) => base + "sqlite-wasm/jswasm/" + f });
    return { sqlite3, db: new sqlite3.oo1.DB(":memory:", "c") };
  })();
  return _boot;
}

/** A WbDataEngine tier backed by real in-page SQLite. Same contract as the floor. */
export class WasmSqlite {
  /** Register a normalized source ({columns, rows: object[]}) as a table. */
  async register(name, norm) {
    const { db } = await bootSqlite();
    const cols = norm.columns;
    db.exec(`DROP TABLE IF EXISTS ${ident(name)}`);
    db.exec(`CREATE TABLE ${ident(name)} (${cols.map(ident).join(", ")})`);
    if (!norm.rows.length) return;
    const stmt = db.prepare(`INSERT INTO ${ident(name)} VALUES (${cols.map(() => "?").join(", ")})`);
    try {
      db.exec("BEGIN");
      for (const row of norm.rows) {
        stmt.bind(cols.map((c) => sqlVal(row[c]))).step();
        stmt.reset(true);
      }
      db.exec("COMMIT");
    } finally {
      stmt.finalize();
    }
  }

  /** Run SQL → WbQueryResult (row-major arrays + per-column inferred types). */
  async query(sql, params = []) {
    const { db } = await bootSqlite();
    const columns = [];
    const rows = db.exec({
      sql,
      bind: params && params.length ? params : undefined,
      rowMode: "array",
      columnNames: columns,
      returnValue: "resultRows",
    });
    const types = columns.map((_c, j) => inferType(rows.map((r) => r[j])));
    return { columns, rows, types, rowCount: rows.length, engine: "sqlite-wasm", sql };
  }
}

function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }

/** Coerce a JS value to something sqlite-wasm can bind (no booleans/objects). */
function sqlVal(v) {
  if (v == null) return null;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (typeof v === "number" || typeof v === "string" || typeof v === "bigint") return v;
  return JSON.stringify(v);
}
