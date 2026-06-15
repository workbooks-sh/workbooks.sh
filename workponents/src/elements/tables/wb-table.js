// <wb-table> — THE tables reinvention: the grid IS a view over a query, not a
// static table. Sort / filter / aggregate run IN the engine (DuckDB on the
// runtime tier · browser duckdb-wasm · the in-JS subset offline) — never in the
// element. The element is a thin, virtualized viewport over a WbQueryResult.
//
// Composition-as-source: the table carries its data + query as source. Reach
// compute ONLY through the src/data layer (getEngine) — exactly the cell pattern
// in docs/wb-doc-cell.js, generalized to the shared DuckDB engine.
//
// Usage (inline data, declared columns):
//   <wb-table rows='[{"region":"North","rev":120}]' searchable>
//     <wb-column field="region" label="Region"></wb-column>
//     <wb-column field="rev" label="Revenue" align="right" format="usd"></wb-column>
//   </wb-table>
//
// Usage (register elsewhere, query a named source):
//   <wb-table src-name="orders" query="SELECT region, sum(rev) AS rev FROM orders GROUP BY region"></wb-table>
//
// Attributes:
//   rows        inline JSON array of row objects (registers an auto-named source)
//   csv         inline CSV text (header row)
//   src-name    name of a source registered via getEngine().register(...)
//   query       full SQL to run (overrides the default SELECT * over src-name)
//   page-size   rows rendered per virtual window (default 50)
//   searchable  show a filter box (filters IN the engine via WHERE … LIKE)
//   variant     card | bare    (visual shell)
//   density     comfortable | compact
//
// Events:
//   wb-table-ready   { detail: { columns, types, engine } }
//   wb-table-query   { detail: { sql, rowCount, engine } }   on every (re)query
//   wb-row-click     { detail: { row: {…}, index } }
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";

const VARIANTS = defineVariants({
  variant: { options: ["card", "bare"], default: "card" },
  density: { options: ["comfortable", "compact"], default: "comfortable" },
});

let _autoId = 0;

export class WbTable extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "rows", "csv", "src-name", "query", "page-size", "searchable"];

  static styles = `
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .shell { border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); overflow: hidden; box-shadow: var(--wb-shadow-sm); }
    :host([variant="bare"]) .shell { border: none; box-shadow: none; background: transparent; }

    .toolbar { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3); border-bottom: 1px solid var(--wb-border);
      background: var(--wb-surface-soft); }
    .toolbar .grow { flex: 1; }
    .search { font: inherit; font-size: var(--wb-text-sm); color: var(--wb-fg);
      background: var(--wb-surface); border: 1px solid var(--wb-border); border-radius: var(--wb-radius-sm);
      padding: var(--wb-space-1) var(--wb-space-2); min-width: 180px; }
    .search:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); border-color: var(--wb-brand); }
    .meta { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }
    .engine { display: inline-flex; align-items: center; gap: var(--wb-space-1); }
    .dot { width: 7px; height: 7px; border-radius: var(--wb-radius-pill); background: var(--wb-brand);
      box-shadow: 0 0 0 3px var(--wb-brand-soft); }
    .engine[data-tier="memory"] .dot { background: var(--wb-warn); box-shadow: 0 0 0 3px rgba(184,134,27,0.18); }
    .engine[data-tier="error"] .dot { background: var(--wb-err); box-shadow: none; }

    .scroll { max-height: var(--wb-table-max-h, 440px); overflow: auto; position: relative; }
    table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: var(--wb-text-sm); }
    thead th { position: sticky; top: 0; z-index: 1; background: var(--wb-surface);
      text-align: left; padding: var(--wb-space-2) var(--wb-space-3); white-space: nowrap;
      border-bottom: 1px solid var(--wb-border-strong); font-family: var(--wb-font-mono);
      font-weight: 600; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.04em;
      color: var(--wb-fg-muted); cursor: pointer; user-select: none; }
    thead th:hover { color: var(--wb-fg); }
    thead th .arrow { color: var(--wb-brand); margin-left: var(--wb-space-1); font-size: 0.9em; }
    th.num, td.num { text-align: right; font-variant-numeric: tabular-nums; }
    th.center, td.center { text-align: center; }

    tbody td { padding: var(--wb-space-2) var(--wb-space-3); border-bottom: 1px solid var(--wb-border);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 320px; }
    :host([density="compact"]) tbody td,
    :host([density="compact"]) thead th { padding: var(--wb-space-1) var(--wb-space-2); }
    tbody tr { cursor: default; }
    tbody tr:hover td { background: var(--wb-surface-soft); }
    tbody td.num { color: var(--wb-fg); }
    .spacer td { padding: 0; border: none; height: 0; }

    .empty { padding: var(--wb-space-5); text-align: center; color: var(--wb-fg-muted); font-size: var(--wb-text-sm); }
    .foot { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3); border-top: 1px solid var(--wb-border);
      font-size: var(--wb-text-sm); color: var(--wb-fg-subtle); }
    .note { color: var(--wb-fg-subtle); }
  `;

  connectedCallback() {
    // Capture source + columns ONCE before the base wipes anything.
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._sort = null;          // { col, dir }
      this._filter = "";
      this._page = 0;
      this._result = null;
      this._tier = "memory";
      this._error = null;
      this._busy = true;
      this._captureSource();
      this._readColumns();
    }
    super.connectedCallback();
    this._load();
  }

  _captureSource() {
    // src-name wins; else inline rows/csv become an auto-named source. The auto
    // name is assigned ONCE per element — re-capture (e.g. an attr change) must
    // not mint a new id, or the query would target a name we never registered.
    this._srcName = this.attr("src-name");
    if (!this._srcName) {
      const rowsAttr = this.attr("rows");
      const csvAttr = this.attr("csv");
      if (!this._autoName) this._autoName = `wb_inline_${++_autoId}`;
      this._srcName = this._autoName;
      if (rowsAttr) this._pendingSource = { json: rowsAttr };
      else if (csvAttr) this._pendingSource = { csv: csvAttr };
      else {
        // maybe inline text content is CSV/JSON
        const text = this.textContent.trim();
        if (text.startsWith("[")) this._pendingSource = { json: text };
        else if (text.includes(",")) this._pendingSource = { csv: text };
      }
    }
  }

  _readColumns() {
    const cols = [...this.querySelectorAll("wb-column")].map((c) => c.config);
    this._declaredColumns = cols.length ? cols : null;
  }

  // Reload when the data source / query changes (e.g. rows set after connect);
  // variant/density/page-size/searchable only re-render (base handles those).
  attributeChangedCallback(name) {
    if (!this._connected) return;
    if (name === "rows" || name === "csv" || name === "src-name" || name === "query") {
      this._pendingSource = null;
      this._captureSource();
      this._load();
    } else {
      this.update();
    }
  }

  /** Called by <wb-column> when its attrs change. */
  _columnsChanged() {
    if (!this._init) return;
    this._readColumns();
    this.update();
  }

  async _load() {
    // Single-flight: overlapping loads would let one load's register()
    // (DROP+CREATE) yank the table out from under another's in-flight query.
    // Coalesce instead — re-run once more if asked while a load is active.
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._busy = true; this._error = null; this.update();
      try {
        if (this._pendingSource) await this._engine.register(this._srcName, this._pendingSource);
        else if (this.hasAttribute("src-name")) await this._engine.whenRegistered(this._srcName);
        await this._run();
      } catch (e) {
        this._error = String(e && e.message || e);
        this._tier = "error";
      }
      this._busy = false;
      this.update();
      this._emit("wb-table-ready", { columns: this._result?.columns || [], types: this._result?.types || [], engine: this._tier });
    } while (this._loadAgain);
    this._loading = false;
  }

  /** Build SQL from query attr (+ engine filter/sort) and run it. */
  async _run() {
    const sql = this._buildSql();
    this._result = await this._engine.query(sql);
    this._tier = this._result.engine || this._engine.provider();
    this._page = 0;
    this._emit("wb-table-query", { sql, rowCount: this._result.rowCount, engine: this._tier });
  }

  _buildSql() {
    const base = this.attr("query");
    const name = this._srcName;
    // Sort + filter run IN the engine. When the author supplied a full query we
    // wrap it as a subquery so WHERE/ORDER still push to SQL over the result.
    const from = base ? `(${base.replace(/;$/, "")}) AS _q` : ident(name);
    let sql = `SELECT * FROM ${from}`;
    const where = [];
    if (this._filter && this._searchableColumns().length) {
      const f = this._filter.replace(/'/g, "''");
      const ors = this._searchableColumns().map((c) => `CAST(${ident(c)} AS VARCHAR) LIKE '%${f}%'`);
      where.push("(" + ors.join(" OR ") + ")");
    }
    if (where.length) sql += " WHERE " + where.join(" AND ");
    if (this._sort) sql += ` ORDER BY ${ident(this._sort.col)} ${this._sort.dir === "desc" ? "DESC" : "ASC"}`;
    return sql;
  }

  _searchableColumns() {
    // Filter across the result's string-ish columns (engine-side LIKE).
    const r = this._result;
    if (!r) return [];
    return r.columns.filter((c, j) => r.types[j] === "string" || r.types[j] == null);
  }

  // ── render ──────────────────────────────────────────────────────────────────
  render() {
    const searchable = this.boolAttr("searchable");
    const tierText = this._busy ? "querying…" : this._error ? "engine error" :
      this._tier === "runtime" ? "engine: runtime DuckDB" :
      this._tier === "duckdb-wasm" ? "engine: DuckDB-wasm (in-browser)" :
      "engine: in-JS (offline)";
    const head = `
      <div class="toolbar">
        ${searchable ? `<input class="search" type="search" placeholder="Filter…" value="${esc(this._filter)}" />` : ""}
        <span class="grow"></span>
        <span class="engine" data-tier="${this._error ? "error" : this._tier}"><span class="dot"></span></span>
        <span class="meta">${this._result ? this._result.rowCount.toLocaleString() + " rows" : ""}</span>
      </div>`;
    return `<div class="shell">${head}${this._renderBody()}<div class="foot"><span class="note">${esc(tierText)}</span>${this._error ? `<span class="note"> — ${esc(this._error)}</span>` : ""}</div></div>`;
  }

  _renderBody() {
    if (this._busy && !this._result) return `<div class="empty">Loading…</div>`;
    const r = this._result;
    if (!r || !r.columns.length) return `<div class="empty">No data.</div>`;
    const cols = this._resolvedColumns(r);
    if (!r.rows.length) return this._headerOnly(cols) + `<div class="empty">No matching rows.</div>`;

    const pageSize = parseInt(this.attr("page-size", "50"), 10) || 50;
    const total = r.rows.length;
    const start = this._page * pageSize;
    const slice = r.rows.slice(start, start + pageSize);
    const before = start;                   // virtual spacer rows above
    const after = Math.max(0, total - start - slice.length);

    const ths = cols.map((c) => {
      const cls = alignClass(c, r);
      const arrow = this._sort && this._sort.col === c.field ? (this._sort.dir === "desc" ? "↓" : "↑") : "";
      return `<th class="${cls}" data-col="${esc(c.field)}">${esc(c.label)}${arrow ? `<span class="arrow">${arrow}</span>` : ""}</th>`;
    }).join("");

    const colIdx = (f) => r.columns.indexOf(f);
    const trs = slice.map((row, i) => {
      const tds = cols.map((c) => {
        const v = row[colIdx(c.field)];
        return `<td class="${alignClass(c, r)}">${esc(fmt(v, c.format))}</td>`;
      }).join("");
      return `<tr data-i="${start + i}">${tds}</tr>`;
    }).join("");

    const spacer = (h) => `<tr class="spacer"><td colspan="${cols.length}" style="height:${h}px"></td></tr>`;
    const rowH = this.attr("density") === "compact" ? 29 : 37;

    return `<div class="scroll"><table>
      <thead><tr>${ths}</tr></thead>
      <tbody>
        ${before ? spacer(before * rowH) : ""}
        ${trs}
        ${after ? spacer(after * rowH) : ""}
      </tbody>
    </table></div>`;
  }

  _headerOnly(cols) {
    const ths = cols.map((c) => `<th>${esc(c.label)}</th>`).join("");
    return `<div class="scroll"><table><thead><tr>${ths}</tr></thead></table></div>`;
  }

  /** Merge declared <wb-column> config with the result's actual columns. */
  _resolvedColumns(r) {
    if (this._declaredColumns) {
      return this._declaredColumns.filter((c) => !c.hidden && r.columns.includes(c.field));
    }
    return r.columns.map((f) => ({ field: f, label: prettify(f), align: null, format: null }));
  }

  update() {
    super.update();
    const root = this.shadowRoot;
    // header sort
    root.querySelectorAll("thead th[data-col]").forEach((th) => {
      th.addEventListener("click", () => this._toggleSort(th.getAttribute("data-col")));
    });
    // search (engine-side filter)
    const search = root.querySelector(".search");
    if (search) {
      // Restore focus + caret across the post-query re-render so typing is smooth.
      if (this._searchFocused) {
        search.focus();
        const end = search.value.length;
        search.setSelectionRange(end, end);
      }
      search.addEventListener("focus", () => { this._searchFocused = true; });
      search.addEventListener("blur", () => { this._searchFocused = false; });
      search.addEventListener("input", (e) => {
        const value = e.target.value;            // capture now (target detaches on re-render)
        clearTimeout(this._t);
        this._t = setTimeout(() => {
          this._filter = value;
          this._run().then(() => this.update());
        }, 140);
      });
    }
    // virtual paging on scroll
    const scroll = root.querySelector(".scroll");
    if (scroll) {
      scroll.addEventListener("scroll", () => {
        const pageSize = parseInt(this.attr("page-size", "50"), 10) || 50;
        const rowH = this.attr("density") === "compact" ? 29 : 37;
        const p = Math.floor(scroll.scrollTop / rowH / pageSize);
        if (p !== this._page) { this._page = p; this._renderRowsInPlace(); }
      });
    }
    // row click
    root.querySelectorAll("tbody tr[data-i]").forEach((tr) => {
      tr.addEventListener("click", () => {
        const i = +tr.getAttribute("data-i");
        const r = this._result;
        const obj = {};
        r.columns.forEach((c, j) => (obj[c] = r.rows[i][j]));
        this._emit("wb-row-click", { row: obj, index: i });
      });
    });
  }

  _renderRowsInPlace() {
    // Re-render preserving scroll position (virtual window moved).
    const scroll = this.shadowRoot.querySelector(".scroll");
    const top = scroll ? scroll.scrollTop : 0;
    this.update();
    const s2 = this.shadowRoot.querySelector(".scroll");
    if (s2) s2.scrollTop = top;
  }

  _toggleSort(col) {
    if (this._sort && this._sort.col === col) {
      this._sort = this._sort.dir === "asc" ? { col, dir: "desc" } : null;
    } else {
      this._sort = { col, dir: "asc" };
    }
    this._run().then(() => this.update());
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

// ── helpers (token-unaware data formatting) ───────────────────────────────────
function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
function prettify(f) { return String(f).replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }
function alignClass(c, r) {
  if (c.align === "right") return "num";
  if (c.align === "center") return "center";
  if (c.align === "left") return "";
  const j = r.columns.indexOf(c.field);
  return (r.types[j] === "number" || r.types[j] === "integer") ? "num" : "";
}
function fmt(v, format) {
  if (v == null) return "";
  if (format === "usd") return "$" + Number(v).toLocaleString(undefined, { maximumFractionDigits: 2 });
  if (format === "num") return Number(v).toLocaleString();
  if (format === "pct") return (Number(v) * (Number(v) <= 1 ? 100 : 1)).toFixed(1) + "%";
  if (typeof v === "number") return Number.isInteger(v) ? v.toLocaleString() : v.toLocaleString(undefined, { maximumFractionDigits: 4 });
  return v;
}

define("wb-table", WbTable);
