// workponents · data — the shared SQLite seam, behind the Host/Dock membrane.
//
// ONE engine, every data surface: `tables`, `data-viz`, `maps`, `records`, and
// `search` all import `getEngine()` and consume the contract in ./contract.js.
// A component NEVER picks where SQL runs — the Host resolves the tier by context
// (the platform-model `local | runtime` seam):
//
//   • runtime — a Workbooks runtime/nexus is connected. SQL routes over the Dock
//     to the workbook's native SQLite VFS (`exqlite`, server-side) via the
//     tenant query route. Data stays OUT of the client; writes are durable
//     (Litestream). This is "the unbundling" — the SQLite is docked out to the
//     nexus so it can be edited live.
//
//   • sqlite-wasm — no runtime. Real SQLite in the page (./sqlite-wasm.js): the
//     full dialect, byte-compatible with the runtime's `exqlite`. ~1MB, lazily
//     loaded once. "The SQLite layer in the workbook itself" — and, ahead, the
//     engine that opens a static workbook's hydrated embedded VFS (the single-HTML
//     format: VFS embedded as a compressed blob, hydrated via DecompressionStream).
//
//   • memory — last-resort floor (./memory-sql.js): the zero-dep in-JS SQL subset,
//     used only if sqlite-wasm can't load (offline, no CDN/self-host). It is a
//     SUBSET — not real SQLite — so sqlite-wasm is preferred whenever reachable.
//
// One SQLite dialect everywhere — native `exqlite` (runtime) and sqlite-wasm
// (browser) are two builds of the same engine, and a workbook's `.sqlite` is
// byte-portable between them. (DuckDB-wasm was removed: 34MB, a divergent dialect,
// and redundant — the workbook already ships SQLite.)

import { getHost } from "../core/host.js";
import { normalizeSource, resultFromObjects } from "./contract.js";
import { WasmSqlite, bootSqlite } from "./sqlite-wasm.js";
import { MemorySql } from "./memory-sql.js";

let _engine = null;

/** The shared engine singleton. Lazy, idempotent — call from any element. */
export function getEngine() {
  if (!_engine) _engine = new WbDataEngine();
  return _engine;
}

export class WbDataEngine {
  constructor() {
    this._host = getHost();
    this._sqlite = new WasmSqlite();  // real in-page SQLite (the local tier)
    this._memory = new MemorySql();   // zero-dep subset (load-failure floor only)
    this._sources = new Map();        // name -> normalized {columns, rows}
    this._provider = null;            // resolved on first use
    this._initPromise = null;
    this._regWaiters = new Map();     // name -> [resolve, ...] awaiting registration
    this._inflightRegs = new Set();   // register() promises still settling
    // Runtime SQL-over-VFS route (tenant SQLite via the Dock). `{tenant}` is
    // filled from the Host. Override per deploy if a runtime exposes another path.
    this.vfsQueryPath = "/api/library/{tenant}/query";
  }

  /**
   * Resolve once `name` is registered (and live on the active provider). Returns
   * immediately if it already is. Lets a declarative element with `src-name`
   * upgrade BEFORE the page calls register() without racing an unknown table —
   * the one ordering hazard shared by every surface.
   */
  whenRegistered(name) {
    if (this._sources.has(name)) return Promise.resolve();
    return new Promise((resolve) => {
      const arr = this._regWaiters.get(name) || [];
      arr.push(resolve);
      this._regWaiters.set(name, arr);
    });
  }

  /** Which tier answers: "runtime" (native VFS) | "sqlite-wasm" (local) | "memory". */
  provider() { return this._provider || (this._runtimeReady() ? "runtime" : "sqlite-wasm"); }

  /** Is a real SQLite engine reachable (runtime VFS or in-page sqlite-wasm)? */
  available() { return this._runtimeReady() || this._provider === "sqlite-wasm"; }

  /** Are writes durable (runtime/nexus `exqlite`) vs local/ephemeral or none? */
  writable() { return this._runtimeReady(); }

  _runtimeReady() {
    return this._host.available("vfs") || (this._host.runtimeUrl != null);
  }

  /** Register a named source so SQL can `FROM <name>`. Idempotent per name. */
  register(name, source) {
    // Track the in-flight promise so a query that references this table before
    // it lands (an element querying a table a SIBLING registers — no src-name
    // declared) can await it and retry, instead of failing "no such table".
    const p = this._doRegister(name, source);
    this._inflightRegs.add(p);
    p.finally(() => this._inflightRegs.delete(p));
    return p;
  }

  async _doRegister(name, source) {
    const norm = normalizeSource(source);
    this._sources.set(name, norm);
    // Seed the floor too, so a sqlite-wasm load failure still answers.
    this._memory.register(name, norm);
    await this._ensureProvider();
    if (this._provider === "runtime") {
      // Inline data pushed into a docked workbook (best-effort). Real workbook
      // tables already live in the VFS and need no registration.
      try {
        await this._host.request(this._regPath(), { body: { name, columns: norm.columns, rows: norm.rows } });
      } catch { /* runtime ingest best-effort; the floor still answers */ }
    } else if (this._provider === "sqlite-wasm") {
      await this._sqlite.register(name, norm);
    }
    // Now queryable on the active provider — release anyone awaiting this source.
    const waiters = this._regWaiters.get(name);
    if (waiters) { this._regWaiters.delete(name); for (const r of waiters) r(); }
  }

  /** query(sql, params?) -> Promise<WbQueryResult>. Every surface's one call. */
  async query(sql, params = []) {
    await this._ensureProvider();
    if (this._provider === "runtime") {
      try {
        const res = await this._host.request(this._queryPath(), { body: { sql, params } });
        const shaped = shapeRuntime(res, sql);
        if (shaped) return shaped;
      } catch { /* fall through to the local engine */ }
    }
    if (this._provider === "sqlite-wasm") {
      try {
        return await this._sqlite.query(sql, params);
      } catch (e) {
        // The table may simply not be registered YET (a sibling's register() is
        // mid-flight). Wait for pending registrations, then retry once.
        if (/no such table/i.test(String(e && e.message || e)) && this._inflightRegs.size) {
          await Promise.allSettled([...this._inflightRegs]);
          return this._sqlite.query(sql, params);
        }
        throw e;
      }
    }
    // Last-resort floor — the zero-dep in-JS subset (sqlite-wasm unavailable).
    return this._memory.query(sql, params);
  }

  // ── provider resolution ────────────────────────────────────────────────────
  async _ensureProvider() {
    if (this._provider) return;
    if (this._initPromise) return this._initPromise;
    // Runtime/nexus SQLite VFS when connected; else real in-page sqlite-wasm;
    // the in-JS subset only if sqlite-wasm can't load (offline, no CDN/self-host).
    this._initPromise = (async () => {
      if (this._runtimeReady()) { this._provider = "runtime"; return; }
      try {
        await bootSqlite();
        this._provider = "sqlite-wasm";
        // No re-registration here: every source arrives via register(), which
        // registers into the resolved provider after awaiting this boot. Looping
        // here too would double-register the same table concurrently (DROP/CREATE
        // racing a sibling's DDL) → transient "no such table".
      } catch {
        this._provider = "memory";
      }
    })();
    return this._initPromise;
  }

  _queryPath() {
    return this.vfsQueryPath.replace("{tenant}", encodeURIComponent(this._host.tenant || "local"));
  }
  _regPath() {
    return this._queryPath().replace(/\/query$/, "/register");
  }
}

/**
 * Shape a runtime SQL response into a WbQueryResult. Tolerant of the row shapes a
 * runtime may return ({columns, rows[][]} columnar, or an array of row-objects).
 * Returns null when unrecognized so query() falls back to the local floor.
 */
function shapeRuntime(res, sql) {
  if (!res) return null;
  if (Array.isArray(res)) {
    return resultFromObjects(res, res.length ? Object.keys(res[0]) : [], "runtime", sql);
  }
  if (Array.isArray(res.rows) && Array.isArray(res.columns)) {
    const types = res.types || res.columns.map(() => "string");
    return { columns: res.columns, rows: res.rows, types, rowCount: res.rows.length, engine: "runtime", sql };
  }
  if (Array.isArray(res.rows)) {
    const cols = res.columns || (res.rows.length ? Object.keys(res.rows[0]) : []);
    return resultFromObjects(res.rows, cols, "runtime", sql);
  }
  return null;
}
