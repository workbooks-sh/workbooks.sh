// workponents · data — THE shared query/result contract.
//
// This is the single data interface every data surface consumes:
// `tables`, `data-viz`, `maps`, `records`, and `search` all talk to ONE engine
// through this shape. It is framework-agnostic, zero-dependency, and TOKEN-UNAWARE
// (pure data — no CSS, no DOM). An element imports `getEngine()` from ./engine.js,
// registers its source once, and runs queries; the element owns render + theme.
//
// The engine is SQLite, resolved by the Host per context: the workbook's native
// SQLite VFS over the runtime (Dock `vfs-query`), in-page sqlite-wasm when static,
// or the in-JS subset floor. One SQL dialect everywhere — write SQLite SQL.
//
// ─────────────────────────────────────────────────────────────────────────────
// Result shape — every query (runtime VFS, in-page sqlite-wasm, or the in-JS
// floor) returns EXACTLY this. Every surface must code against this and nothing
// else:
//
//   /** @typedef {Object} WbQueryResult
//    *  @property {string[]}    columns  ordered column names
//    *  @property {any[][]}     rows     row-major; rows[i][j] is column j of row i
//    *  @property {WbColType[]} types    per-column logical type (columns.length)
//    *  @property {number}      rowCount rows.length (convenience)
//    *  @property {string}      [engine] which tier answered: runtime|sqlite-wasm|memory
//    *  @property {string}      [sql]    the SQL actually executed (debug)
//    */
//
//   WbColType ∈ "number" | "integer" | "string" | "boolean" | "date" | "json"
//
// Engine surface (engine.js implements this; every surface reuses it verbatim):
//
//   query(sql: string, params?: any[]) -> Promise<WbQueryResult>
//   register(name: string, source: WbSource) -> Promise<void>   // makes a table
//   whenRegistered(name: string) -> Promise<void>  // await before querying it
//   available() -> boolean      // is a real SQLite tier reachable (vs the floor)
//   writable() -> boolean       // are writes durable (runtime VFS) vs local/none
//   provider() -> string        // "runtime" | "sqlite-wasm" | "memory"
//
// Source registration — "a workbook's data IS its source" (for INLINE data; a
// real workbook's tables already live in its SQLite VFS, no registration). One of:
//
//   { rows: object[] }                         inline array of row objects
//   { columns: string[], rows: any[][] }       columnar inline
//   { csv: string }                            CSV text (header row)
//   { json: string | object[] }                JSON text or parsed array
//   { url: string, format?: "csv"|"json" }     fetched (browser/runtime)
//
// `params` use positional `?` placeholders (SQLite style). All tiers bind the same.
// ─────────────────────────────────────────────────────────────────────────────

/** Normalize any WbSource into { columns, rows(object[]) } for registration. */
export function normalizeSource(src) {
  if (!src || typeof src !== "object") throw new Error("wb-data: source must be an object");
  if (Array.isArray(src.rows) && src.columns) {
    // columnar inline → objects
    const cols = src.columns;
    return { columns: cols, rows: src.rows.map((r) => objFromRow(cols, r)) };
  }
  if (Array.isArray(src.rows)) {
    const cols = inferColumns(src.rows);
    return { columns: cols, rows: src.rows };
  }
  if (typeof src.csv === "string") return parseCsv(src.csv);
  if (src.json != null) {
    const arr = typeof src.json === "string" ? JSON.parse(src.json) : src.json;
    if (!Array.isArray(arr)) throw new Error("wb-data: json source must be an array of rows");
    return { columns: inferColumns(arr), rows: arr };
  }
  throw new Error("wb-data: unsupported source (need rows|columns+rows|csv|json|url|arrow)");
}

function objFromRow(cols, row) {
  if (Array.isArray(row)) {
    const o = {};
    cols.forEach((c, i) => (o[c] = row[i]));
    return o;
  }
  return row;
}

function inferColumns(rows) {
  const seen = new Set();
  const cols = [];
  for (const r of rows) for (const k of Object.keys(r)) if (!seen.has(k)) { seen.add(k); cols.push(k); }
  return cols;
}

/** Minimal RFC-4180-ish CSV parse (quotes, escaped quotes, commas, newlines). */
export function parseCsv(text) {
  const rows = [];
  let field = "", row = [], inQ = false;
  const t = text.replace(/\r\n?/g, "\n");
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (inQ) {
      if (c === '"') { if (t[i + 1] === '"') { field += '"'; i++; } else inQ = false; }
      else field += c;
    } else if (c === '"') inQ = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n") { row.push(field); rows.push(row); field = ""; row = []; }
    else field += c;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  const filtered = rows.filter((r) => r.length > 1 || (r.length === 1 && r[0] !== ""));
  if (!filtered.length) return { columns: [], rows: [] };
  const columns = filtered[0].map((h) => h.trim());
  const out = filtered.slice(1).map((r) => {
    const o = {};
    columns.forEach((col, i) => (o[col] = coerce(r[i])));
    return o;
  });
  return { columns, rows: out };
}

/** Coerce a CSV/string cell to number/boolean where it is unambiguous. */
export function coerce(v) {
  if (v == null) return null;
  const s = String(v).trim();
  if (s === "") return null;
  if (s === "true") return true;
  if (s === "false") return false;
  if (/^-?\d+$/.test(s)) return parseInt(s, 10);
  if (/^-?\d*\.\d+$/.test(s)) return parseFloat(s);
  return s;
}

/** Infer a WbColType from a sample of column values. */
export function inferType(values) {
  let n = 0, allInt = true, num = 0, bool = 0, total = 0;
  for (const v of values) {
    if (v == null) continue;
    total++;
    if (typeof v === "boolean") { bool++; continue; }
    if (typeof v === "number") { num++; if (!Number.isInteger(v)) allInt = false; continue; }
    n++;
  }
  if (total === 0) return "string";
  if (bool === total) return "boolean";
  if (num === total) return allInt ? "integer" : "number";
  return "string";
}

/** Build a WbQueryResult (columns/rows array-of-array/types) from row objects. */
export function resultFromObjects(rowObjs, columns, engine, sql) {
  const cols = columns || inferColumns(rowObjs);
  const rows = rowObjs.map((o) => cols.map((c) => o[c] ?? null));
  const types = cols.map((c, j) => inferType(rows.map((r) => r[j])));
  return { columns: cols, rows, types, rowCount: rows.length, engine, sql };
}
