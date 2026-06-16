// <work-query> — THE declarative data source: a named, queryable dataset written
// directly into the document. It declares intent (a name + the SQL) and routes
// execution through the Host capability seam; the SAME tag answers over SQLite or
// Postgres — the host decides WHERE the query actually runs (embedded sqlite-wasm
// when static, native exqlite when docked to a runtime, a real Postgres connection
// in a nexus). The author writes intent, not a driver (see docs/WORK-FORMAT.md, the
// "SQL in HTML" section).
//
// One source element + a `from=` binding — no per-database tags. A view component
// (work-table / work-chart / work-record-list) reads a result by name:
//
//   <work-query name="big-orders" db="sales"
//     sql="select * from orders where total > 100"></work-query>
//   <work-table  from="big-orders"></work-table>
//   <work-chart  from="big-orders" type="bar" x="region" y="total"></work-chart>
//
// HOW IT WIRES (no fabricated rows — real execution or an honest stub):
//   work-query runs its `sql` through the shared data engine (../../data/engine.js)
//   — the ONE seam the whole library queries. The engine resolves the tier per
//   context behind the Dock membrane: `runtime` routes SQL over the Dock to the
//   tenant's native SQLite VFS (server-side exqlite) when a runtime/nexus is
//   connected; `sqlite-wasm` runs real in-page SQLite when static; `memory` is the
//   zero-dependency in-JS subset floor used ONLY if sqlite-wasm cannot load. The
//   result rows are then REGISTERED back into the engine under `name`, so a view's
//   `from="name"` resolves through the engine's existing whenRegistered/register
//   plumbing — exactly the path `src-name=` already uses. No second data store, no
//   synthetic rows: when no real SQLite tier is reachable the engine answers from
//   the in-JS floor and the element reports `engine="memory"` honestly.
//
// PROVIDER OVERRIDE (the documented host hookup point):
//   The default resolver IS the shared engine. To route a named work-query through
//   a custom backend (e.g. a host-brokered Postgres connection the engine does not
//   model), set a resolver — either imperatively on the element:
//       document.querySelector('work-query').resolver =
//         async ({ sql, db, name }) => /* WbQueryResult | row-object[] */;
//   or by name via `provider=`, looked up on a host-populated registry:
//       window.__WB_QUERY_PROVIDERS__ = {
//         warehouse: async ({ sql, db, name }) => /* … */,
//       };
//       <work-query name="orders" provider="warehouse" db="warehouse" sql="…">
//   A resolver returns either a WbQueryResult ({columns, rows[][], types}) or a
//   plain array of row objects; both are normalized and registered under `name`.
//   This is the ONE place a deployment hooks a non-engine datasource — the views
//   never change.
//
// Attributes:
//   name      the dataset name a view binds to via from="<name>" (required)
//   db        logical database/schema the query targets — advisory metadata passed
//             to the resolver/host so it can route (the default engine ignores it;
//             a Postgres/warehouse provider uses it). NOT a driver selector.
//   sql       the SQL to execute (SQLite dialect for the default engine)
//   provider  optional resolver name in window.__WB_QUERY_PROVIDERS__ (host hookup)
//
// Reflected:
//   ready     present once the result is registered (from= binders await this)
//   error     the error message if the query failed (absent on success)
//
// Events:
//   work-query-ready  { detail: { name, rowCount, columns, types, engine } }
//   work-query-error  { detail: { name, error } }
//
// Presentation: none by default (display:none) — it is a data declaration, not a
// view. Set `debug` to surface a one-line status chip for authoring.
import { WbElement, html, css, define } from "../../core/element.js";
import { getEngine } from "../../data/index.js";
import { normalizeSource, resultFromObjects } from "../../data/contract.js";

export class WorkQuery extends WbElement {
  static props = ["name", "db", "sql", "provider", "debug"];

  static styles = css`
    :host { display: none; }
    :host([debug]) { display: block; font-family: var(--work-font-mono); font-size: var(--work-text-2xs); }
    .chip { display: inline-flex; align-items: center; gap: var(--work-space-1);
      padding: var(--work-space-px) var(--work-space-2); border-radius: var(--work-radius-pill);
      border: 1px solid var(--work-border); background: var(--work-surface-soft); color: var(--work-fg-muted); }
    .dot { width: 7px; height: 7px; border-radius: var(--work-radius-pill); background: var(--work-brand);
      box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .chip[data-tier="memory"] .dot { background: var(--work-warn); box-shadow: 0 0 0 3px var(--work-warn-soft); }
    .chip[data-tier="error"] .dot { background: var(--work-err); box-shadow: none; }
  `;

  /** Optional async resolver: ({sql, db, name}) -> WbQueryResult | row-object[]. */
  resolver = null;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._tier = "memory";
      this._error = null;
      this._rowCount = 0;
      this._columns = [];
    }
    super.connectedCallback();
    this._run();
  }

  attributeChangedCallback(name, old, val) {
    super.attributeChangedCallback(name, old, val);
    if (!this._init) return;
    if (name === "sql" || name === "name" || name === "db" || name === "provider") this._run();
    else this.requestUpdate();
  }

  // Resolve the SQL through the seam, then register the result under `name` so
  // every from="<name>" view reads it through the engine's normal path. Idempotent
  // + single-flight: an attribute change mid-run coalesces into one more run.
  async _run() {
    const name = this.attr("name");
    const sql = this.attr("sql");
    if (!name || !sql) return;
    if (this._busy) { this._again = true; return; }
    this._busy = true;
    do {
      this._again = false;
      this._error = null;
      this.removeAttribute("ready");
      this.removeAttribute("error");
      try {
        const result = await this._resolve(sql);
        // Register the result rows under `name`; views bind via from= → src-name.
        await this._engine.register(name, { rows: rowObjects(result) });
        this._tier = result.engine || this._engine.provider();
        this._rowCount = result.rowCount ?? (result.rows ? result.rows.length : 0);
        this._columns = result.columns || [];
        this._types = result.types || [];
        this.setAttribute("ready", "");
        this._emit("work-query-ready", {
          name, rowCount: this._rowCount, columns: this._columns, types: this._types, engine: this._tier,
        });
      } catch (e) {
        this._error = String((e && e.message) || e);
        this._tier = "error";
        this.setAttribute("error", this._error);
        this._emit("work-query-error", { name, error: this._error });
      }
      this.requestUpdate();
    } while (this._again);
    this._busy = false;
  }

  // The resolver: a custom provider (settable property OR provider= registry name)
  // wins; otherwise the shared engine IS the resolver — the real Host seam.
  async _resolve(sql) {
    const fn = this.resolver || this._namedProvider();
    if (fn) {
      const out = await fn({ sql, db: this.attr("db"), name: this.attr("name") });
      return shapeResolved(out, sql);
    }
    // Default: run through the shared engine (runtime VFS / sqlite-wasm / floor).
    return this._engine.query(sql);
  }

  _namedProvider() {
    const key = this.attr("provider");
    if (!key || typeof window === "undefined") return null;
    const reg = window.__WB_QUERY_PROVIDERS__;
    return (reg && typeof reg[key] === "function") ? reg[key] : null;
  }

  render() {
    if (!this.boolAttr("debug")) return html``;
    const tier = this._error ? "error" : this._tier;
    const label = this._error ? `error: ${this._error}`
      : `${this.attr("name") || "?"} · ${this._rowCount} rows · ${tier}`;
    return html`<span class="chip" data-tier=${tier}><span class="dot"></span>${label}</span>`;
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

// Normalize a resolver return (WbQueryResult OR row-object[]) to a WbQueryResult.
function shapeResolved(out, sql) {
  if (Array.isArray(out)) return resultFromObjects(out, undefined, "provider", sql);
  if (out && Array.isArray(out.rows) && Array.isArray(out.columns)) {
    const types = out.types || out.columns.map(() => "string");
    return { columns: out.columns, rows: out.rows, types, rowCount: out.rows.length, engine: out.engine || "provider", sql };
  }
  if (out && Array.isArray(out.rows)) return resultFromObjects(out.rows, out.columns, out.engine || "provider", sql);
  throw new Error("work-query: provider must return a WbQueryResult or an array of row objects");
}

// WbQueryResult (columns + rows[][]) → row objects, for engine.register({rows}).
function rowObjects(result) {
  if (Array.isArray(result.rows) && !Array.isArray(result.rows[0]) && result.rows.length) return result.rows; // already objects
  const cols = result.columns || [];
  return (result.rows || []).map((r) => {
    const o = {};
    cols.forEach((c, j) => (o[c] = r[j]));
    return o;
  });
}

define("work-query", WorkQuery);
