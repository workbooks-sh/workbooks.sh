// <work-search> — THE search reinvention: search IS a query. An instant search box
// over a registered source where EACH KEYSTROKE runs an engine query (debounced
// WHERE … LIKE across the searchable fields) — never a JS .filter() over a
// preloaded array. The result list is a thin, themed viewport over a
// WbQueryResult, exactly like <work-table>. Reach compute ONLY through src/data
// (getEngine) — runtime DuckDB · browser duckdb-wasm · the in-JS offline floor.
//
// Usage (register elsewhere, search a named source):
//   <work-search src-name="people" fields="name,role,city" label="Search people"
//     title-field="name" subtitle-field="role"></work-search>
//
// Usage (inline rows become an auto-named source):
//   <work-search rows='[{"name":"Ada","role":"Eng"}]' fields="name,role"></work-search>
//
// Attributes:
//   src-name      name of a source registered via getEngine().register(...)
//   rows          inline JSON array of row objects (auto-registers a source)
//   csv           inline CSV text (header row)
//   query         base SQL to search over (wrapped as a subquery); default is the source
//   fields        comma list of columns to match (LIKE) AND to display; default = all string cols
//   title-field   column rendered as the result title (default: first field)
//   subtitle-field column rendered as a muted subtitle (optional)
//   limit         max results per query (default 8)
//   placeholder   input placeholder
//   label         a11y label for the box
//   open-on-focus show the result panel as soon as the box is focused (default: only when typing)
//   variant       card | bare
//   size          sm | md | lg
//
// Events:
//   work-search-input   { detail: { value } }                       on every (debounced) query
//   work-search-query   { detail: { sql, rowCount, engine, value } } on every (re)query
//   work-search-select  { detail: { row, index } }                  Enter / click a result
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import { highlight } from "./rank.js";
import { ref, createRef } from "lit/directives/ref.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";

const VARIANTS = defineVariants({
  variant: { options: ["card", "bare"], default: "card" },
  size: { options: ["sm", "md", "lg"], default: "md" },
});

let _autoId = 0;

export class WorkSearch extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "rows", "csv", "src-name", "query", "fields", "placeholder", "limit", "open-on-focus"];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); position: relative; }
    .box { position: relative; }
    .field { display: flex; align-items: center; gap: var(--work-space-2);
      background: var(--work-surface); border: 1px solid var(--work-border); border-radius: var(--work-radius);
      padding: var(--work-space-2) var(--work-space-3); box-shadow: var(--work-shadow-sm);
      transition: border-color var(--work-dur) var(--work-ease), box-shadow var(--work-dur) var(--work-ease); }
    :host([variant="bare"]) .field { border-radius: var(--work-radius-sm); box-shadow: none; background: var(--work-surface-soft); }
    .field:focus-within { border-color: var(--work-brand); box-shadow: 0 0 0 3px var(--work-ring); }
    .icon { width: 16px; height: 16px; color: var(--work-fg-subtle); flex: none; }
    :host([size="sm"]) .field { padding: var(--work-space-1) var(--work-space-2); }
    :host([size="lg"]) .field { padding: var(--work-space-3) var(--work-space-4); }
    input { flex: 1; min-width: 0; font: inherit; font-size: var(--work-text); color: var(--work-fg);
      background: transparent; border: none; outline: none; }
    :host([size="sm"]) input { font-size: var(--work-text-sm); }
    :host([size="lg"]) input { font-size: var(--work-text-lg); }
    input::placeholder { color: var(--work-fg-subtle); }
    .spin { width: 13px; height: 13px; border-radius: var(--work-radius-pill); flex: none;
      border: 2px solid var(--work-border-strong); border-top-color: var(--work-brand); animation: spin .7s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .clear { cursor: pointer; color: var(--work-fg-subtle); font-size: var(--work-text); line-height: 1; padding: var(--work-space-2px); border: none; background: none; }
    .clear:hover { color: var(--work-fg); }

    .panel { position: absolute; left: 0; right: 0; top: calc(100% + 6px); z-index: 30;
      background: var(--work-surface); border: 1px solid var(--work-border); border-radius: var(--work-radius);
      box-shadow: var(--work-shadow); overflow: hidden; }
    .results { list-style: none; margin: 0; padding: var(--work-space-1); max-height: 320px; overflow: auto; }
    .row { display: flex; flex-direction: column; gap: var(--work-space-px); padding: var(--work-space-2) var(--work-space-3);
      border-radius: var(--work-radius-sm); cursor: pointer; }
    .row[aria-selected="true"] { background: var(--work-brand-soft); }
    .row:hover { background: var(--work-surface-soft); }
    .row .title { font-size: var(--work-text); color: var(--work-fg); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .row .sub { font-size: var(--work-text-sm); color: var(--work-fg-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    mark { background: var(--work-brand-soft); color: var(--work-brand-ink, var(--work-fg)); border-radius: var(--work-radius-xs); padding: 0 var(--work-space-px); }
    [data-work-theme="dark"] mark, [data-work-theme="signal"] mark { color: var(--work-brand); }

    .state { padding: var(--work-space-4) var(--work-space-3); text-align: center; color: var(--work-fg-muted); font-size: var(--work-text-sm); }
    .foot { display: flex; align-items: center; gap: var(--work-space-2); padding: var(--work-space-1) var(--work-space-3);
      border-top: 1px solid var(--work-border); font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-subtle); }
    .dot { width: 6px; height: 6px; border-radius: var(--work-radius-pill); background: var(--work-brand); box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .foot[data-tier="memory"] .dot { background: var(--work-warn); box-shadow: 0 0 0 var(--work-space-3px) var(--work-warn-glow); }
    .foot[data-tier="error"] .dot { background: var(--work-err); box-shadow: none; }
    .grow { flex: 1; }
  `;

  _inputRef = createRef();

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._value = "";
      this._result = null;
      this._busy = false;
      this._open = false;
      this._active = 0;
      this._tier = this._engine.provider();
      this._error = null;
      this._captureSource();
    }
    super.connectedCallback();
    // Pre-register inline source so the first query can run.
    if (this._pendingSource) this._engine.register(this._srcName, this._pendingSource).catch(() => {});
  }

  _captureSource() {
    this._srcName = this.attr("src-name");
    if (!this._srcName) {
      if (!this._autoName) this._autoName = `work_search_${++_autoId}`;
      this._srcName = this._autoName;
      const rowsAttr = this.attr("rows");
      const csvAttr = this.attr("csv");
      if (rowsAttr) this._pendingSource = { json: rowsAttr };
      else if (csvAttr) this._pendingSource = { csv: csvAttr };
      else {
        const text = this.textContent.trim();
        if (text.startsWith("[")) this._pendingSource = { json: text };
        else if (text.includes(",")) this._pendingSource = { csv: text };
      }
    }
  }

  attributeChangedCallback(name, old, val) {
    super.attributeChangedCallback?.(name, old, val);
    if (!this._connected) return;
    if (name === "rows" || name === "csv" || name === "src-name" || name === "query") {
      this._pendingSource = null;
      this._captureSource();
      if (this._pendingSource) this._engine.register(this._srcName, this._pendingSource).catch(() => {});
      if (this._value) this._runQuery();
    }
  }

  _fields() {
    const f = this.attr("fields");
    return f ? f.split(",").map((s) => s.trim()).filter(Boolean) : null;
  }

  /** Build the search SQL — WHERE … LIKE across the searchable fields, IN the engine. */
  _buildSql() {
    const base = this.attr("query");
    const from = base ? `(${base.replace(/;$/, "")}) AS _q` : ident(this._srcName);
    const fields = this._searchFields;
    const limit = parseInt(this.attr("limit", "8"), 10) || 8;
    const term = this._value.replace(/'/g, "''");
    // SQLite LIKE is case-insensitive for ASCII on every tier (native exqlite and
    // the in-JS floor), so one operator works everywhere — no per-provider fork.
    let sql = `SELECT * FROM ${from}`;
    if (term && fields.length) {
      const ors = fields.map((c) => `CAST(${ident(c)} AS VARCHAR) LIKE '%${term}%'`);
      sql += ` WHERE ${ors.join(" OR ")}`;
    }
    sql += ` LIMIT ${limit}`;
    return sql;
  }

  /** Resolve which columns to match against (declared fields, else all string cols). */
  async _resolveFields() {
    if (this._searchFields) return;
    const declared = this._fields();
    if (declared) { this._searchFields = declared; return; }
    // Probe one row to infer string columns.
    const base = this.attr("query");
    const from = base ? `(${base.replace(/;$/, "")}) AS _q` : ident(this._srcName);
    try {
      const probe = await this._engine.query(`SELECT * FROM ${from} LIMIT 1`);
      this._searchFields = probe.columns.filter((c, j) => probe.types[j] === "string" || probe.types[j] == null);
      if (!this._searchFields.length) this._searchFields = probe.columns;
    } catch {
      this._searchFields = [];
    }
  }

  async _runQuery() {
    // Single-flight, last-wins: a newer keystroke query supersedes an in-flight
    // one (and never races a register()'s DROP/CREATE on the same table).
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._busy = true; this._error = null; this.requestUpdate();
      try {
        if (this.hasAttribute("src-name")) await this._engine.whenRegistered(this._srcName);
        else if (this._pendingSource) await this._engine.whenRegistered(this._srcName);
        await this._resolveFields();
        const sql = this._buildSql();
        this._result = await this._engine.query(sql);
        this._tier = this._result.engine || this._engine.provider();
        this._active = 0;
        this._emit("work-search-query", { sql, rowCount: this._result.rowCount, engine: this._tier, value: this._value });
      } catch (e) {
        this._error = String((e && e.message) || e);
        this._tier = "error";
        this._result = null;
      }
      this._busy = false;
      this.requestUpdate();
    } while (this._loadAgain);
    this._loading = false;
  }

  // ── render ──────────────────────────────────────────────────────────────────
  render() {
    const ph = this.attr("placeholder", "Search…");
    const label = this.attr("label", "Search");
    const showClear = this._value.length > 0;
    return html`
      <div class="box">
        <div class="field" part="field">
          <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
            <circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line>
          </svg>
          <input ${ref(this._inputRef)} type="text" role="combobox" aria-expanded=${String(this._open)} aria-label=${label}
            placeholder=${ph} .value=${this._value} autocomplete="off" spellcheck="false"
            @focus=${this._onFocus} @blur=${this._onBlur} @input=${this._onInput} @keydown=${this._onKey} />
          ${this._busy ? html`<span class="spin" aria-hidden="true"></span>` : ""}
          ${showClear ? html`<button class="clear" type="button" aria-label="Clear" tabindex="-1"
            @mousedown=${this._onClear}>✕</button>` : ""}
        </div>
        ${this._open ? this._renderPanel() : ""}
      </div>`;
  }

  _renderPanel() {
    const r = this._result;
    const tierText = this._error ? "engine error" :
      this._tier === "runtime" ? "runtime DuckDB" :
      this._tier === "duckdb-wasm" ? "DuckDB-wasm" : "in-JS engine";
    let body;
    if (this._error) body = html`<div class="state">${this._error}</div>`;
    else if (this._busy && !r) body = html`<div class="state">Searching…</div>`;
    else if (!this._value) body = html`<div class="state">Type to search.</div>`;
    else if (!r || !r.rows.length) body = html`<div class="state">No matches for “${this._value}”.</div>`;
    else body = this._renderResults(r);
    return html`<div class="panel" part="panel">${body}
      <div class="foot" data-tier=${this._error ? "error" : this._tier}><span class="dot"></span><span>${tierText}</span><span class="grow"></span><span>${r ? r.rowCount : 0} ${r && r.rowCount === 1 ? "result" : "results"}</span></div></div>`;
  }

  _renderResults(r) {
    const fields = this._searchFields || [];
    const titleField = this.attr("title-field") || fields[0] || r.columns[0];
    const subField = this.attr("subtitle-field");
    const ti = r.columns.indexOf(titleField);
    const si = subField ? r.columns.indexOf(subField) : -1;
    return html`<ul class="results" role="listbox">${r.rows.map((row, i) => {
      const title = ti >= 0 ? row[ti] : row[0];
      const sub = si >= 0 ? row[si] : null;
      return html`<li class="row" role="option" aria-selected=${String(i === this._active)} data-i=${i}
        @mousedown=${(e) => { e.preventDefault(); this._select(i); }}
        @mousemove=${() => { if (i !== this._active) { this._active = i; this._syncActive(); } }}>
        <span class="title">${unsafeHTML(highlightTerm(title, this._value))}</span>
        ${sub != null && sub !== "" ? html`<span class="sub">${unsafeHTML(highlightTerm(sub, this._value))}</span>` : ""}
      </li>`;
    })}</ul>`;
  }

  // Restore focus + caret after a surgical re-render while the input is focused.
  updated() {
    const input = this._inputRef.value;
    if (input && this._inputFocused && this.shadowRoot.activeElement !== input) {
      input.focus();
      const e = input.value.length;
      input.setSelectionRange(e, e);
    }
  }

  _onFocus = () => {
    this._inputFocused = true;
    if (this.boolAttr("open-on-focus") || this._value) { this._open = true; this.requestUpdate(); }
  };
  _onBlur = () => {
    this._inputFocused = false;
    // Delay close so a result click registers first.
    setTimeout(() => { if (!this._inputFocused) { this._open = false; this.requestUpdate(); } }, 120);
  };
  _onInput = (e) => {
    const value = e.target.value;
    this._value = value;
    this._open = true;
    this._emit("work-search-input", { value });
    clearTimeout(this._t);
    this._t = setTimeout(() => this._runQuery(), 140);
    this.requestUpdate();
  };
  _onClear = (e) => {
    e.preventDefault();
    this._value = ""; this._result = null; this._open = false;
    this._emit("work-search-input", { value: "" });
    this.requestUpdate();
  };

  _onKey(e) {
    const n = this._result ? this._result.rows.length : 0;
    if (e.key === "ArrowDown") { e.preventDefault(); if (n) { this._active = (this._active + 1) % n; this._syncActive(); } }
    else if (e.key === "ArrowUp") { e.preventDefault(); if (n) { this._active = (this._active - 1 + n) % n; this._syncActive(); } }
    else if (e.key === "Enter") { if (n) { e.preventDefault(); this._select(this._active); } }
    else if (e.key === "Escape") { this._open = false; this.requestUpdate(); }
  }

  /** Cheap selection move without a full re-query/re-render. */
  _syncActive() {
    const rows = this.shadowRoot.querySelectorAll(".row[data-i]");
    rows.forEach((li) => {
      const sel = +li.getAttribute("data-i") === this._active;
      li.setAttribute("aria-selected", String(sel));
      if (sel) li.scrollIntoView({ block: "nearest" });
    });
  }

  _select(i) {
    const r = this._result;
    if (!r || !r.rows[i]) return;
    const obj = {};
    r.columns.forEach((c, j) => (obj[c] = r.rows[i][j]));
    this._emit("work-search-select", { row: obj, index: i });
    this._open = false;
    this.requestUpdate();
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
/** Highlight the literal search term (substring) inside an engine-returned cell. */
function highlightTerm(text, term) {
  const t = String(text ?? "");
  const q = String(term ?? "").trim();
  if (!q) return esc(t);
  const idx = t.toLowerCase().indexOf(q.toLowerCase());
  if (idx < 0) return esc(t);
  return highlight(t, [[idx, idx + q.length]]);
}

define("work-search", WorkSearch);
