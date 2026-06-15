// workponents · data — the shared DuckDB engine, behind the Host/Dock seam.
//
// ONE engine, three surfaces: `tables`, `data-viz`, and `maps` all import
// `getEngine()` here and consume the contract in ./contract.js. The engine is a
// lazy, idempotent singleton — a single shared connection — so registering a
// dataset for a table makes it queryable by a chart and a map on the same page.
//
// Provider resolution (platform-model: same element, swap provider per target):
//
//   1. runtime      — when the Host exposes DuckDB (`host.available("duckdb")`
//                     or a configured runtime URL), queries route to the runtime
//                     tier over the Dock seam (POST /data/query, POST /data/register).
//                     This is where the in-repo `runtime/compilers/duckdb/duckdb.wasm`
//                     engine lives — built in-sandbox, run server-side under wasmtime.
//                     Best for huge datasets (no multi-MB browser download).
//
//   2. duckdb-wasm  — browser-local in-WASM DuckDB. Lazily imported from the
//                     official ESM build (no bundler, no `bun install` — a module
//                     URL loaded at runtime). Real SQL in the browser, offline.
//                     Override the URL via window.__WB_DUCKDB_WASM__ to self-host.
//
//   3. memory       — the zero-dep in-JS SQL subset (./memory-sql.js). Guarantees
//                     a real, engine-computed grid with no runtime AND no network.
//                     Always present; the floor the trio degrades to cleanly.
//
// NOTE on the in-repo artifact: `runtime/compilers/duckdb/duckdb.wasm` is a WASI
// *command* whose main() runs a fixed CREATE/INSERT/SELECT and exits (a proof
// artifact, not an arbitrary-SQL engine). It is therefore the RUNTIME-tier engine
// reached via Host — not directly instantiable as a query engine in the browser.
// Browser-local SQL uses duckdb-wasm; the JS memory engine is the offline floor.

import { getHost } from "../core/host.js";
import { normalizeSource, resultFromObjects } from "./contract.js";
import { MemorySql } from "./memory-sql.js";

// Official duckdb-wasm ESM (MVP bundle — broad browser support, no bundler).
const DEFAULT_DUCKDB_WASM =
  "https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.29.0/+esm";

let _engine = null;

/** The shared engine singleton. Lazy, idempotent — call from any element. */
export function getEngine() {
  if (!_engine) _engine = new WbDataEngine();
  return _engine;
}

export class WbDataEngine {
  constructor() {
    this._host = getHost();
    this._memory = new MemorySql();
    this._sources = new Map();        // name -> normalized {columns, rows}
    this._provider = null;            // resolved on first use
    this._duck = null;                // { db, conn } once duckdb-wasm boots
    this._initPromise = null;
    this._regWaiters = new Map();     // name -> [resolve, ...] awaiting registration
  }

  /**
   * Resolve once `name` is registered (and live on the active provider). Returns
   * immediately if it already is. Lets a declarative element with `src-name`
   * upgrade BEFORE the page calls register() without racing an unknown table —
   * the one ordering hazard shared by all three surfaces.
   */
  whenRegistered(name) {
    if (this._sources.has(name)) return Promise.resolve();
    return new Promise((resolve) => {
      const arr = this._regWaiters.get(name) || [];
      arr.push(resolve);
      this._regWaiters.set(name, arr);
    });
  }

  /** Which tier answers queries: "runtime" | "duckdb-wasm" | "memory". */
  provider() { return this._provider || (this._runtimeReady() ? "runtime" : "memory"); }

  /** Is a real DuckDB engine reachable (vs the in-JS fallback)? */
  available() { return this._runtimeReady() || this._provider === "duckdb-wasm"; }

  _runtimeReady() {
    return this._host.available("duckdb") || (this._host.runtimeUrl != null);
  }

  /** Register a named source so SQL can `FROM <name>`. Idempotent per name. */
  async register(name, source) {
    const norm = normalizeSource(source);
    this._sources.set(name, norm);
    // Always seed the memory engine (the floor); also push to a live tier if up.
    this._memory.register(name, norm);
    await this._ensureProvider();
    if (this._provider === "runtime") {
      try {
        await this._host.request("/data/register", { body: { name, columns: norm.columns, rows: norm.rows } });
      } catch { /* runtime register best-effort; memory still answers */ }
    } else if (this._provider === "duckdb-wasm" && this._duck) {
      await this._duckRegister(name, norm);
    }
    // Now queryable on the active provider — release anyone awaiting this source.
    const waiters = this._regWaiters.get(name);
    if (waiters) { this._regWaiters.delete(name); for (const r of waiters) r(); }
  }

  /** query(sql, params?) -> Promise<WbQueryResult>. The trio's one call. */
  async query(sql, params = []) {
    await this._ensureProvider();
    if (this._provider === "runtime") {
      try {
        const res = await this._host.request("/data/query", { body: { sql, params } });
        if (res && res.columns) return shapeRuntime(res, sql);
      } catch { /* fall through to local */ }
    }
    if (this._provider === "duckdb-wasm" && this._duck) {
      try { return await this._duckQuery(sql, params); }
      catch (e) { /* fall through to memory on browser-engine error */ }
    }
    return this._memory.query(sql, params);
  }

  // ── provider resolution ────────────────────────────────────────────────────
  async _ensureProvider() {
    if (this._provider) return;
    if (this._initPromise) return this._initPromise;
    this._initPromise = (async () => {
      if (this._runtimeReady()) { this._provider = "runtime"; return; }
      // Try browser duckdb-wasm; if anything fails, settle on memory.
      try {
        await this._bootDuckWasm();
        this._provider = "duckdb-wasm";
        // re-register any sources captured before boot
        for (const [name, norm] of this._sources) await this._duckRegister(name, norm);
      } catch {
        this._provider = "memory";
      }
    })();
    return this._initPromise;
  }

  async _bootDuckWasm() {
    if (typeof window === "undefined") throw new Error("no window");
    const url = (typeof window !== "undefined" && window.__WB_DUCKDB_WASM__) || DEFAULT_DUCKDB_WASM;
    const duckdb = await import(/* @vite-ignore */ url);
    const bundles = duckdb.getJsDelivrBundles();
    const bundle = await duckdb.selectBundle(bundles);
    const worker = await duckdb.createWorker(bundle.mainWorker);
    const logger = new duckdb.ConsoleLogger(duckdb.LogLevel.WARNING);
    const db = new duckdb.AsyncDuckDB(logger, worker);
    await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
    const conn = await db.connect();
    this._duck = { duckdb, db, conn };
  }

  async _duckRegister(name, norm) {
    const { conn } = this._duck;
    await conn.query(`DROP TABLE IF EXISTS ${ident(name)}`);
    const json = JSON.stringify(norm.rows);
    const fname = `__wb_${name}.json`;
    await this._duck.db.registerFileText(fname, json);
    await conn.query(`CREATE TABLE ${ident(name)} AS SELECT * FROM read_json_auto('${fname}')`);
  }

  async _duckQuery(sql, params) {
    const { conn } = this._duck;
    let table;
    if (params && params.length) {
      const stmt = await conn.prepare(sql);
      table = await stmt.query(...params);
      await stmt.close();
    } else {
      table = await conn.query(sql);
    }
    const columns = table.schema.fields.map((f) => f.name);
    const rowObjs = table.toArray().map((r) => {
      const o = r.toJSON ? r.toJSON() : r;
      const out = {};
      for (const c of columns) out[c] = normVal(o[c]);
      return out;
    });
    return resultFromObjects(rowObjs, columns, "duckdb-wasm", sql);
  }
}

function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function normVal(v) {
  if (typeof v === "bigint") return Number(v);
  return v;
}

/** Shape a runtime /data/query response into a WbQueryResult. */
function shapeRuntime(res, sql) {
  const columns = res.columns || [];
  const rows = res.rows || [];
  const types = res.types || columns.map(() => "string");
  return { columns, rows, types, rowCount: rows.length, engine: "runtime", sql };
}
