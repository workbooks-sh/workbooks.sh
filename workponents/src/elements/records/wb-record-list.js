// <work-record-list> — the master index of entities: a card / list view over a
// query (each row = one entity card), NOT a grid. This is the distinct records
// surface — where wb-table is a dense tabular viewport, work-record-list is an
// entity browser (a title + a few summary fields per card), the master half of a
// master-detail pair. Reuses the SAME shared engine as wb-table / work-record
// (getEngine) — never a second data store.
//
// Selecting a card emits `work-record-select` carrying the row's key/value + the
// full row; wire it to a <work-record>'s value/where to drive a detail pane.
//
// Usage (named source, drive a detail record):
//   <work-record-list src-name="customers"
//     query="SELECT id, name, tier, mrr FROM customers ORDER BY mrr DESC"
//     key="id" title-field="name" subtitle-field="tier"
//     fields="mrr" formats="mrr:usd" searchable></work-record-list>
//
// Attributes:
//   src-name       a source registered via getEngine().register(...)
//   query          full SQL over the source (default SELECT * over src-name)
//   key            the identifying column emitted on select (default "id")
//   title-field    column shown as the card title (default first column)
//   subtitle-field column shown as a muted subtitle (optional)
//   fields         comma list of summary columns shown as label:value chips
//   formats        "col:usd,col2:pct" numeric format hints (work-field-value)
//   searchable     show a filter box (filters IN the engine via WHERE … LIKE)
//   layout         cards | rows   (variant)
//   variant        card | bare    (visual shell)
//   selected       the key value of the currently active card (reflected)
//
// Events:
//   work-record-list-ready  { detail: { rowCount, columns, types, engine } }
//   work-record-select      { detail: { key, value, row, index } }
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import { hintFor, splitHint } from "./wb-record.js";
import "./wb-field-value.js";

const VARIANTS = defineVariants({
  layout: { options: ["cards", "rows"], default: "cards" },
  variant: { options: ["card", "bare"], default: "card" },
});

export class WbRecordList extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "src-name", "query", "key", "title-field", "subtitle-field", "fields",
    "formats", "searchable", "selected",
  ];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell { border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-surface); overflow: hidden; box-shadow: var(--work-shadow-sm); }
    :host([variant="bare"]) .shell { border: none; box-shadow: none; background: transparent; }

    .toolbar { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-3); border-bottom: 1px solid var(--work-border);
      background: var(--work-surface-soft); }
    .toolbar .grow { flex: 1; }
    .search { font: inherit; font-size: var(--work-text-sm); color: var(--work-fg);
      background: var(--work-surface); border: 1px solid var(--work-border); border-radius: var(--work-radius-sm);
      padding: var(--work-space-1) var(--work-space-2); min-width: 160px; }
    .search:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); border-color: var(--work-brand); }
    .meta { font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-muted); }

    .list { max-height: var(--work-record-list-max-h, 480px); overflow: auto;
      padding: var(--work-space-3); display: grid; gap: var(--work-space-3);
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); }
    :host([layout="rows"]) .list { display: flex; flex-direction: column; gap: var(--work-space-2); padding: var(--work-space-2); }

    .card { text-align: left; cursor: pointer; font: inherit; color: var(--work-fg);
      border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-surface); padding: var(--work-space-3);
      display: flex; flex-direction: column; gap: var(--work-space-1);
      transition: border-color var(--work-dur) var(--work-ease), box-shadow var(--work-dur) var(--work-ease), transform var(--work-dur) var(--work-ease); }
    .card:hover { border-color: var(--work-border-strong); transform: translateY(-1px); box-shadow: var(--work-shadow-sm); }
    .card[aria-selected="true"] { border-color: var(--work-brand); box-shadow: 0 0 0 1px var(--work-brand), var(--work-shadow-sm); background: var(--work-brand-soft); }
    .card:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); }
    :host([layout="rows"]) .card { flex-direction: row; align-items: center; gap: var(--work-space-3); }

    .title { font-weight: 600; font-size: var(--work-text); letter-spacing: -.005em;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    :host([layout="rows"]) .title { flex: 1; min-width: 0; }
    .subtitle { font-size: var(--work-text-sm); color: var(--work-fg-muted); }
    .chips { display: flex; flex-wrap: wrap; gap: var(--work-space-1) var(--work-space-3); margin-top: var(--work-space-1); }
    :host([layout="rows"]) .chips { margin-top: 0; }
    .chip { display: inline-flex; flex-direction: column; gap: var(--work-space-px); }
    .chip .k { font-family: var(--work-font-mono); font-size: var(--work-text-2xs); text-transform: uppercase;
      letter-spacing: .05em; color: var(--work-fg-subtle); }

    .foot { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-3); border-top: 1px solid var(--work-border);
      font-size: var(--work-text-sm); color: var(--work-fg-subtle); }
    .engine { display: inline-flex; align-items: center; gap: var(--work-space-1); }
    .dot { width: 7px; height: 7px; border-radius: var(--work-radius-pill); background: var(--work-brand);
      box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .engine[data-tier="memory"] .dot { background: var(--work-warn); box-shadow: 0 0 0 var(--work-space-3px) var(--work-warn-glow); }
    .engine[data-tier="error"] .dot { background: var(--work-err); box-shadow: none; }
    .note { color: var(--work-fg-subtle); } .grow { flex: 1; }
    .empty { padding: var(--work-space-5); text-align: center; color: var(--work-fg-muted); font-size: var(--work-text-sm); }
  `;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._result = null;
      this._filter = "";
      this._tier = "memory";
      this._error = null;
      this._busy = true;
    }
    super.connectedCallback();
    this._load();
  }

  attributeChangedCallback(name, old, val) {
    super.attributeChangedCallback(name, old, val);
    if (!this._connected) return;
    if (name === "src-name" || name === "query") { this._load(); }
  }

  async _load() {
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._busy = true; this._error = null; this.requestUpdate();
      try {
        const sname = this.attr("src-name");
        if (sname) await this._engine.whenRegistered(sname);
        await this._run();
      } catch (e) {
        this._error = String((e && e.message) || e);
        this._tier = "error";
      }
      this._busy = false;
      this.requestUpdate();
      this._emit("work-record-list-ready", {
        rowCount: this._result?.rowCount || 0,
        columns: this._result?.columns || [],
        types: this._result?.types || [],
        engine: this._tier,
      });
    } while (this._loadAgain);
    this._loading = false;
  }

  async _run() {
    const sql = this._buildSql();
    this._result = await this._engine.query(sql);
    this._tier = this._result.engine || this._engine.provider();
  }

  _buildSql() {
    const base = this.attr("query");
    const name = this.attr("src-name");
    const from = base ? `(${base.replace(/;$/, "")}) AS _q` : ident(name || "");
    let sql = `SELECT * FROM ${from}`;
    if (this._filter) {
      const f = this._filter.replace(/'/g, "''");
      const cols = this._searchCols();
      if (cols.length) {
        const ors = cols.map((c) => `CAST(${ident(c)} AS VARCHAR) LIKE '%${f}%'`);
        // wrap so the search filters the (possibly ordered) base result
        sql = `SELECT * FROM (${sql}) AS _s WHERE ${ors.join(" OR ")}`;
      }
    }
    return sql;
  }

  _searchCols() {
    const r = this._result;
    if (!r) return [];
    return r.columns.filter((c, j) => r.types[j] === "string" || r.types[j] == null);
  }

  _keyCol() { return this.attr("key") || (this._result?.columns[0]) || "id"; }
  _titleCol() { return this.attr("title-field") || (this._result?.columns[0]); }

  _summaryFields() {
    const r = this._result;
    if (!r) return [];
    return (this.attr("fields") || "").split(",").map((s) => s.trim())
      .filter((c) => c && r.columns.includes(c))
      .map((field) => ({ field, label: prettify(field), type: r.types[r.columns.indexOf(field)] || "string", ...splitHint(hintFor(this.attr("formats"), field)) }));
  }

  // ── render ──────────────────────────────────────────────────────────────────
  render() {
    const searchable = this.boolAttr("searchable");
    const tierText = this._busy ? "querying…" : this._error ? "engine error" :
      this._tier === "runtime" ? "engine: runtime DuckDB" :
      this._tier === "duckdb-wasm" ? "engine: DuckDB-wasm (in-browser)" :
      "engine: in-JS (offline)";
    const head = html`
      <div class="toolbar">
        ${searchable ? html`<input class="search" type="search" placeholder="Filter…"
          .value=${this._filter} @input=${this._onSearch} />` : null}
        <span class="grow"></span>
        <span class="meta">${this._result ? this._result.rowCount.toLocaleString() + " items" : ""}</span>
      </div>`;
    return html`<div class="shell">${head}${this._renderBody()}
      <div class="foot">
        <span class="engine" data-tier=${this._error ? "error" : this._tier}><span class="dot"></span></span>
        <span class="note">${tierText}</span><span class="grow"></span>
      </div></div>`;
  }

  _renderBody() {
    if (this._busy && !this._result) return html`<div class="empty">Loading…</div>`;
    if (this._error) return html`<div class="empty">Could not load — ${this._error}</div>`;
    const r = this._result;
    if (!r || !r.rows.length) return html`<div class="empty">${this._filter ? "No matching records." : "No records."}</div>`;

    const keyCol = this._keyCol(), titleCol = this._titleCol();
    const subCol = this.attr("subtitle-field");
    const summary = this._summaryFields();
    const idx = (c) => r.columns.indexOf(c);
    const selected = this.attr("selected");

    const cards = r.rows.map((row, i) => {
      const keyVal = row[idx(keyCol)];
      const title = titleCol != null ? row[idx(titleCol)] : keyVal;
      const sub = subCol ? row[idx(subCol)] : null;
      const isSel = selected != null && String(keyVal) === String(selected);
      const chips = summary.map((c) => {
        const v = row[idx(c.field)];
        return html`<span class="chip"><span class="k">${c.label}</span>
          <work-field-value type=${c.type} format=${c.format ?? ""} display=${c.display ?? ""}
            value=${v ?? ""}></work-field-value></span>`;
      });
      return html`<button class="card" role="option" aria-selected=${String(isSel)}
        data-i=${i} data-key=${keyVal ?? ""} @click=${() => this._select(i)}>
        <span class="title">${title ?? "—"}</span>
        ${sub != null && sub !== "" ? html`<span class="subtitle">${sub}</span>` : null}
        ${chips.length ? html`<span class="chips">${chips}</span>` : null}
      </button>`;
    });

    return html`<div class="list" role="listbox">${cards}</div>`;
  }

  // ── interaction ───────────────────────────────────────────────────────────
  // Debounced search: filters IN the engine, then re-renders. Lit's surgical
  // update keeps the live <input> (and its focus/caret) intact across re-renders.
  _onSearch(e) {
    const value = e.target.value;
    clearTimeout(this._t);
    this._t = setTimeout(() => { this._filter = value; this._run().then(() => this.requestUpdate()); }, 140);
  }

  _select(i) {
    const r = this._result;
    if (!r || !r.rows[i]) return;
    const keyCol = this._keyCol();
    const row = r.rows[i];
    const obj = {};
    r.columns.forEach((c, j) => (obj[c] = row[j]));
    const value = row[r.columns.indexOf(keyCol)];
    this.setAttribute("selected", value == null ? "" : String(value));
    this._emit("work-record-select", { key: keyCol, value, row: obj, index: i });
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

// ── helpers ───────────────────────────────────────────────────────────────────
function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function prettify(f) { return String(f).replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }

define("work-record-list", WbRecordList);
