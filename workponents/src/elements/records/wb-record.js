// <work-record> — THE records reinvention: the detail view of ONE entity. A record
// IS a row. A source (src-name / query) + a selector (where / id, or key+value)
// resolves to exactly one row of a WbQueryResult; the element renders it as a
// typed field layout — label + a <work-field-value> per column, type-aware off the
// result's `types[]`. Same shared engine as wb-table (getEngine) — never a second
// data store; a record is just a query that returns one row.
//
// Selection is master→detail friendly: set `where`/`id`/`value` from a
// <work-record-list>'s work-record-select event to drive a detail pane off the same
// source. Composition-as-source: the record carries its source + selector.
//
// Editable mode (optional) writes back through the Host/Dock seam
// (this.host.request("/data/update", …)) — NOT through the read-only engine. With
// no reachable Host it degrades to read-only and shows a note.
//
// Usage (named source, select by id):
//   <work-record src-name="customers" key="id" value="C-1004"></work-record>
//
// Usage (full query + WHERE selector, grid layout, editable):
//   <work-record src-name="customers"
//     query="SELECT id, name, tier, mrr, signed, active FROM customers"
//     where="id = 'C-1004'" layout="grid" editable></work-record>
//
// Attributes:
//   src-name    a source registered via getEngine().register(...)
//   query       full SQL over the source (overrides the default SELECT *)
//   where       SQL predicate selecting the row (wrapped around the query)
//   key + value select the row where key = value (sugar over `where`)
//   id          shorthand: selects where the "id" column = id (uses `key` if set)
//   fields      comma list restricting/ordering which columns show (else all)
//   formats     "col:hint" per-column display hints (the author's lens on the
//               engine's type): numeric formats usd|num|pct, OR a display mode
//               date|badge|link|bool — wins over the engine type (e.g. a DATE
//               DuckDB returns as epoch-int → formats="signed:date")
//   layout      stacked | grid | inline   (variant)
//   variant     card | bare                (visual shell)
//   editable    enable write-back via the Host (degrades read-only with no Host)
//   table       table name the Host writes to (default = src-name)
//   title-field column whose value labels the record header (default first col)
//
// Events:
//   work-record-ready  { detail: { row, columns, types, engine, found } }
//   work-record-save   { detail: { changes, ok, error } }   after an edit write-back
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import "./wb-field-value.js";

const VARIANTS = defineVariants({
  layout: { options: ["stacked", "grid", "inline"], default: "stacked" },
  variant: { options: ["card", "bare"], default: "card" },
});

export class WbRecord extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "src-name", "query", "where", "key", "value", "id", "fields", "formats",
    "editable", "table", "title-field",
  ];

  static styles = css`
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .shell { border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); overflow: hidden; box-shadow: var(--wb-shadow-sm); }
    :host([variant="bare"]) .shell { border: none; box-shadow: none; background: transparent; }

    .head { display: flex; align-items: center; gap: var(--wb-space-3);
      padding: var(--wb-space-3) var(--wb-space-4); border-bottom: 1px solid var(--wb-border);
      background: var(--wb-surface-soft); }
    .head .title { font-family: var(--wb-font-display, var(--wb-font)); font-weight: 600;
      font-size: var(--wb-text-lg); letter-spacing: -.01em; flex: 1; min-width: 0;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .head .actions { display: inline-flex; gap: var(--wb-space-2); }
    .btn { font: 600 var(--wb-text-sm)/1 var(--wb-font-mono, monospace);
      padding: var(--wb-space-2) var(--wb-space-3); border-radius: var(--wb-radius-sm);
      border: 1.5px solid var(--wb-border-strong); background: var(--wb-surface);
      color: var(--wb-fg); cursor: pointer; }
    .btn:hover { border-color: var(--wb-brand); color: var(--wb-brand); }
    .btn.primary { background: var(--wb-brand); color: var(--wb-on-brand); border-color: transparent; }
    .btn:disabled { opacity: .5; pointer-events: none; }

    .fields { padding: var(--wb-space-4); display: flex; flex-direction: column; gap: var(--wb-space-3); }
    :host([layout="grid"]) .fields { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: var(--wb-space-4); }
    .field { display: flex; flex-direction: column; gap: var(--wb-space-1); min-width: 0; }
    :host([layout="inline"]) .fields { display: block; }
    :host([layout="inline"]) .field { display: grid; grid-template-columns: 160px 1fr; align-items: baseline;
      gap: var(--wb-space-3); padding: var(--wb-space-2) 0; border-bottom: 1px solid var(--wb-border); }
    :host([layout="inline"]) .field:last-child { border-bottom: none; }
    .label { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); font-weight: 600;
      text-transform: uppercase; letter-spacing: .04em; color: var(--wb-fg-subtle); }
    .val { font-size: var(--wb-text); color: var(--wb-fg); min-width: 0; overflow-wrap: anywhere; }
    .val input { font: inherit; font-size: var(--wb-text); color: var(--wb-fg); width: 100%;
      background: var(--wb-surface); border: 1px solid var(--wb-border); border-radius: var(--wb-radius-sm);
      padding: var(--wb-space-1) var(--wb-space-2); box-sizing: border-box; }
    .val input:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); border-color: var(--wb-brand); }

    .foot { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-4); border-top: 1px solid var(--wb-border);
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
      this._row = null;
      this._tier = "memory";
      this._error = null;
      this._busy = true;
      this._editing = false;
      this._edits = {};
      this._saveNote = null;
    }
    super.connectedCallback();
    this._load();
  }

  // Reload when the source / selector changes (master-detail selection drives
  // where/value/id). Layout/variant only re-render (Lit handles those reactively).
  attributeChangedCallback(name, old, val) {
    super.attributeChangedCallback(name, old, val);
    if (!this._connected) return;
    if (["src-name", "query", "where", "key", "value", "id"].includes(name)) {
      this._editing = false; this._edits = {}; this._saveNote = null;
      this._load();
    }
  }

  async _load() {
    // Single-flight, last-wins — master-detail selection drives rapid re-loads.
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._busy = true; this._error = null; this.requestUpdate();
      try {
        const name = this.attr("src-name");
        if (name) await this._engine.whenRegistered(name);
        const sql = this._buildSql();
        this._result = await this._engine.query(sql);
        this._tier = this._result.engine || this._engine.provider();
        this._row = this._result.rows.length ? this._result.rows[0] : null;
      } catch (e) {
        this._error = String((e && e.message) || e);
        this._tier = "error";
        this._row = null;
      }
      this._busy = false;
      this.requestUpdate();
      this._emit("work-record-ready", {
        row: this._rowObject(),
        columns: this._result?.columns || [],
        types: this._result?.types || [],
        engine: this._tier,
        found: this._row != null,
      });
    } while (this._loadAgain);
    this._loading = false;
  }

  /** A query returning the ONE selected row (LIMIT 1) — a record is a row. */
  _buildSql() {
    const base = this.attr("query");
    const name = this.attr("src-name");
    const from = base ? `(${base.replace(/;$/, "")}) AS _r` : ident(name || "");
    const pred = this._selector();
    let sql = `SELECT * FROM ${from}`;
    if (pred) sql += ` WHERE ${pred}`;
    sql += " LIMIT 1";
    return sql;
  }

  /** Build the row selector: explicit where wins, else key=value / id. */
  _selector() {
    const where = this.attr("where");
    if (where) return where;
    const key = this.attr("key") || "id";
    const value = this.attr("value") != null ? this.attr("value") : this.attr("id");
    if (value == null) return null;
    return `${ident(key)} = ${sqlLiteral(value)}`;
  }

  _rowObject() {
    const r = this._result, row = this._row;
    if (!r || !row) return null;
    const o = {};
    r.columns.forEach((c, j) => (o[c] = row[j]));
    return o;
  }

  /** Columns to display, in order — `fields` attr restricts/orders, else all. */
  _displayColumns() {
    const r = this._result;
    if (!r) return [];
    const want = (this.attr("fields") || "").split(",").map((s) => s.trim()).filter(Boolean);
    const cols = want.length ? want.filter((c) => r.columns.includes(c)) : r.columns.slice();
    return cols.map((field) => ({
      field,
      label: prettify(field),
      type: r.types[r.columns.indexOf(field)] || "string",
      ...splitHint(hintFor(this.attr("formats"), field)),
    }));
  }

  _titleText() {
    const o = this._rowObject();
    if (!o) return "";
    const tf = this.attr("title-field");
    if (tf && o[tf] != null) return String(o[tf]);
    const first = this._displayColumns()[0];
    return first && o[first.field] != null ? String(o[first.field]) : "Record";
  }

  // ── render ──────────────────────────────────────────────────────────────────
  render() {
    const tierText = this._busy ? "querying…" : this._error ? "engine error" :
      this._tier === "runtime" ? "engine: runtime DuckDB" :
      this._tier === "duckdb-wasm" ? "engine: DuckDB-wasm (in-browser)" :
      "engine: in-JS (offline)";
    const canEdit = this.boolAttr("editable");
    const hostOk = this._hostWritable();

    let body;
    if (this._busy && !this._result) body = html`<div class="empty">Loading…</div>`;
    else if (this._error) body = html`<div class="empty">Could not load record — ${this._error}</div>`;
    else if (!this._row) body = html`<div class="empty">No matching record.</div>`;
    else body = this._renderFields();

    const actions = (this._row && canEdit) ? (
      this._editing
        ? html`<button class="btn primary" ?disabled=${!hostOk} @click=${() => this._onAction("save")}>Save</button>
               <button class="btn" @click=${() => this._onAction("cancel")}>Cancel</button>`
        : html`<button class="btn" @click=${() => this._onAction("edit")}>Edit</button>`
    ) : null;

    const head = this._row
      ? html`<div class="head"><span class="title">${this._titleText()}</span><span class="actions">${actions}</span></div>`
      : null;

    const editNote = (canEdit && !hostOk)
      ? html`<span class="note"> — read-only (no Host write seam)</span>` : null;
    const saveNote = this._saveNote ? html`<span class="note"> — ${this._saveNote}</span>` : null;

    return html`<div class="shell">${head}${body}
      <div class="foot">
        <span class="engine" data-tier=${this._error ? "error" : this._tier}><span class="dot"></span></span>
        <span class="note">${tierText}</span>${editNote}${saveNote}
        <span class="grow"></span>
      </div></div>`;
  }

  _renderFields() {
    const o = this._rowObject();
    const editing = this._editing;
    const fields = this._displayColumns().map((c) => {
      const v = o[c.field];
      const inner = editing
        ? html`<input type="text" .value=${String(this._edits[c.field] ?? (v ?? ""))}
            @input=${(e) => { this._edits[c.field] = e.target.value; }} />`
        : html`<work-field-value type=${c.type} format=${c.format ?? ""} display=${c.display ?? ""}
            value=${v ?? ""}></work-field-value>`;
      return html`<div class="field"><span class="label">${c.label}</span><span class="val">${inner}</span></div>`;
    });
    return html`<div class="fields">${fields}</div>`;
  }

  // ── interaction ───────────────────────────────────────────────────────────
  _onAction(act) {
    if (act === "edit") { this._editing = true; this._edits = {}; this._saveNote = null; this.requestUpdate(); }
    else if (act === "cancel") { this._editing = false; this._edits = {}; this.requestUpdate(); }
    else if (act === "save") this._save();
  }

  _hostWritable() {
    // The Host can write only when a runtime seam is reachable (the engine itself
    // is read-only). available() is true when a runtime URL is configured.
    const h = this.host;
    return !!(h && h.runtimeUrl);
  }

  async _save() {
    const changes = {};
    for (const [k, v] of Object.entries(this._edits)) {
      const orig = this._rowObject()?.[k];
      if (String(v) !== String(orig ?? "")) changes[k] = v;
    }
    if (!Object.keys(changes).length) { this._editing = false; this.requestUpdate(); return; }
    const table = this.attr("table") || this.attr("src-name");
    const where = this._selector();
    try {
      // Write back through the Host/Dock seam — NOT the read-only engine.
      await this.host.request("/data/update", { body: { table, set: changes, where } });
      // Reflect locally so the detail updates without a full re-query round-trip.
      const r = this._result;
      for (const [k, v] of Object.entries(changes)) {
        const j = r.columns.indexOf(k);
        if (j >= 0) this._row[j] = coerceToType(v, r.types[j]);
      }
      this._editing = false; this._edits = {}; this._saveNote = "saved";
      this.requestUpdate();
      this._emit("work-record-save", { changes, ok: true });
    } catch (e) {
      this._saveNote = "save failed: " + String((e && e.message) || e);
      this.requestUpdate();
      this._emit("work-record-save", { changes, ok: false, error: String((e && e.message) || e) });
    }
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

// ── helpers (token-unaware) ───────────────────────────────────────────────────
function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function sqlLiteral(v) {
  if (v == null) return "NULL";
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
  return "'" + String(v).replace(/'/g, "''") + "'";
}
function prettify(f) { return String(f).replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }
// A per-column display hint (the author's lens) → either a numeric `format` or a
// `display` mode for <work-field-value>. Lets a DATE that DuckDB returns as an
// epoch-int still read as a date, without touching the read-only engine.
export const NUMERIC_FORMATS = ["usd", "num", "pct"];
export function hintFor(map, field) {
  if (!map) return null;
  for (const pair of String(map).split(",")) {
    const [c, h] = pair.split(":").map((s) => s.trim());
    if (c === field && h) return h;
  }
  return null;
}
export function splitHint(hint) {
  if (!hint) return { format: null, display: null };
  return NUMERIC_FORMATS.includes(hint) ? { format: hint, display: null } : { format: null, display: hint };
}
function coerceToType(v, type) {
  if (type === "number" || type === "integer") { const n = Number(v); return Number.isFinite(n) ? n : v; }
  if (type === "boolean") { const s = String(v).toLowerCase(); return s === "true" || s === "1" || s === "yes"; }
  return v;
}

define("work-record", WbRecord);
