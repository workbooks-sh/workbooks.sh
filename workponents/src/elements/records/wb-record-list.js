// <wb-record-list> — the master index of entities: a card / list view over a
// query (each row = one entity card), NOT a grid. This is the distinct records
// surface — where wb-table is a dense tabular viewport, wb-record-list is an
// entity browser (a title + a few summary fields per card), the master half of a
// master-detail pair. Reuses the SAME shared engine as wb-table / wb-record
// (getEngine) — never a second data store.
//
// Selecting a card emits `wb-record-select` carrying the row's key/value + the
// full row; wire it to a <wb-record>'s value/where to drive a detail pane.
//
// Usage (named source, drive a detail record):
//   <wb-record-list src-name="customers"
//     query="SELECT id, name, tier, mrr FROM customers ORDER BY mrr DESC"
//     key="id" title-field="name" subtitle-field="tier"
//     fields="mrr" formats="mrr:usd" searchable></wb-record-list>
//
// Attributes:
//   src-name       a source registered via getEngine().register(...)
//   query          full SQL over the source (default SELECT * over src-name)
//   key            the identifying column emitted on select (default "id")
//   title-field    column shown as the card title (default first column)
//   subtitle-field column shown as a muted subtitle (optional)
//   fields         comma list of summary columns shown as label:value chips
//   formats        "col:usd,col2:pct" numeric format hints (wb-field-value)
//   searchable     show a filter box (filters IN the engine via WHERE … LIKE)
//   layout         cards | rows   (variant)
//   variant        card | bare    (visual shell)
//   selected       the key value of the currently active card (reflected)
//
// Events:
//   wb-record-list-ready  { detail: { rowCount, columns, types, engine } }
//   wb-record-select      { detail: { key, value, row, index } }
import { WbElement, define } from "../../core/element.js";
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
      padding: var(--wb-space-1) var(--wb-space-2); min-width: 160px; }
    .search:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); border-color: var(--wb-brand); }
    .meta { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }

    .list { max-height: var(--wb-record-list-max-h, 480px); overflow: auto;
      padding: var(--wb-space-3); display: grid; gap: var(--wb-space-3);
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); }
    :host([layout="rows"]) .list { display: flex; flex-direction: column; gap: var(--wb-space-2); padding: var(--wb-space-2); }

    .card { text-align: left; cursor: pointer; font: inherit; color: var(--wb-fg);
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); padding: var(--wb-space-3);
      display: flex; flex-direction: column; gap: var(--wb-space-1);
      transition: border-color var(--wb-dur) var(--wb-ease), box-shadow var(--wb-dur) var(--wb-ease), transform var(--wb-dur) var(--wb-ease); }
    .card:hover { border-color: var(--wb-border-strong); transform: translateY(-1px); box-shadow: var(--wb-shadow-sm); }
    .card[aria-selected="true"] { border-color: var(--wb-brand); box-shadow: 0 0 0 1px var(--wb-brand), var(--wb-shadow-sm); background: var(--wb-brand-soft); }
    .card:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    :host([layout="rows"]) .card { flex-direction: row; align-items: center; gap: var(--wb-space-3); }

    .title { font-weight: 600; font-size: var(--wb-text); letter-spacing: -.005em;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    :host([layout="rows"]) .title { flex: 1; min-width: 0; }
    .subtitle { font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }
    .chips { display: flex; flex-wrap: wrap; gap: var(--wb-space-1) var(--wb-space-3); margin-top: var(--wb-space-1); }
    :host([layout="rows"]) .chips { margin-top: 0; }
    .chip { display: inline-flex; flex-direction: column; gap: 1px; }
    .chip .k { font-family: var(--wb-font-mono); font-size: 10px; text-transform: uppercase;
      letter-spacing: .05em; color: var(--wb-fg-subtle); }

    .foot { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3); border-top: 1px solid var(--wb-border);
      font-size: var(--wb-text-sm); color: var(--wb-fg-subtle); }
    .engine { display: inline-flex; align-items: center; gap: var(--wb-space-1); }
    .dot { width: 7px; height: 7px; border-radius: var(--wb-radius-pill); background: var(--wb-brand);
      box-shadow: 0 0 0 3px var(--wb-brand-soft); }
    .engine[data-tier="memory"] .dot { background: var(--wb-warn); box-shadow: 0 0 0 3px rgba(184,134,27,0.18); }
    .engine[data-tier="error"] .dot { background: var(--wb-err); box-shadow: none; }
    .note { color: var(--wb-fg-subtle); } .grow { flex: 1; }
    .empty { padding: var(--wb-space-5); text-align: center; color: var(--wb-fg-muted); font-size: var(--wb-text-sm); }
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
      this._searchFocused = false;
    }
    super.connectedCallback();
    this._load();
  }

  attributeChangedCallback(name) {
    if (!this._connected) return;
    if (name === "src-name" || name === "query") { this._load(); }
    else if (name === "selected") { this._reflectSelection(); }
    else { this.update(); }
  }

  async _load() {
    this._busy = true; this._error = null; this.update();
    try {
      const sname = this.attr("src-name");
      if (sname) await this._engine.whenRegistered(sname);
      await this._run();
    } catch (e) {
      this._error = String((e && e.message) || e);
      this._tier = "error";
    }
    this._busy = false;
    this.update();
    this._emit("wb-record-list-ready", {
      rowCount: this._result?.rowCount || 0,
      columns: this._result?.columns || [],
      types: this._result?.types || [],
      engine: this._tier,
    });
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
    const head = `
      <div class="toolbar">
        ${searchable ? `<input class="search" type="search" placeholder="Filter…" value="${esc(this._filter)}" />` : ""}
        <span class="grow"></span>
        <span class="meta">${this._result ? this._result.rowCount.toLocaleString() + " items" : ""}</span>
      </div>`;
    return `<div class="shell">${head}${this._renderBody()}
      <div class="foot">
        <span class="engine" data-tier="${this._error ? "error" : this._tier}"><span class="dot"></span></span>
        <span class="note">${esc(tierText)}</span><span class="grow"></span>
      </div></div>`;
  }

  _renderBody() {
    if (this._busy && !this._result) return `<div class="empty">Loading…</div>`;
    if (this._error) return `<div class="empty">Could not load — ${esc(this._error)}</div>`;
    const r = this._result;
    if (!r || !r.rows.length) return `<div class="empty">${this._filter ? "No matching records." : "No records."}</div>`;

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
        return `<span class="chip"><span class="k">${esc(c.label)}</span>
          <wb-field-value type="${esc(c.type)}"${c.format ? ` format="${esc(c.format)}"` : ""}${c.display ? ` display="${esc(c.display)}"` : ""} value="${esc(v ?? "")}"></wb-field-value></span>`;
      }).join("");
      return `<button class="card" role="option" aria-selected="${isSel}" data-i="${i}" data-key="${esc(keyVal ?? "")}">
        <span class="title">${esc(title ?? "—")}</span>
        ${sub != null && sub !== "" ? `<span class="subtitle">${esc(sub)}</span>` : ""}
        ${chips ? `<span class="chips">${chips}</span>` : ""}
      </button>`;
    }).join("");

    return `<div class="list" role="listbox">${cards}</div>`;
  }

  // ── interaction ───────────────────────────────────────────────────────────
  update() {
    super.update();
    const root = this.shadowRoot;
    root.querySelectorAll(".card").forEach((card) => {
      card.addEventListener("click", () => this._select(+card.getAttribute("data-i")));
    });
    const search = root.querySelector(".search");
    if (search) {
      if (this._searchFocused) { search.focus(); const e = search.value.length; search.setSelectionRange(e, e); }
      search.addEventListener("focus", () => { this._searchFocused = true; });
      search.addEventListener("blur", () => { this._searchFocused = false; });
      search.addEventListener("input", (e) => {
        const value = e.target.value;
        clearTimeout(this._t);
        this._t = setTimeout(() => { this._filter = value; this._run().then(() => this.update()); }, 140);
      });
    }
  }

  _reflectSelection() {
    // Cheap selection update without a re-query: just toggle aria-selected.
    const selected = this.attr("selected");
    this.shadowRoot.querySelectorAll(".card").forEach((card) => {
      card.setAttribute("aria-selected", String(String(card.getAttribute("data-key")) === String(selected)));
    });
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
    this._emit("wb-record-select", { key: keyCol, value, row: obj, index: i });
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

// ── helpers ───────────────────────────────────────────────────────────────────
function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
function prettify(f) { return String(f).replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }

define("wb-record-list", WbRecordList);
