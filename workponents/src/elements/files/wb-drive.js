// <work-drive> — a file browser whose index IS a query over the workbook's store.
//
// The files reinvention: a file is not a separate filesystem object, it's a ROW
// in the workbook's SQLite — a content-addressed record (name, path/key, type,
// size, modified, content-hash). So a "drive" is just a view over a query, the
// same way <work-table> is a grid over a query and <work-record-list> is a card
// index. It reuses the SAME shared engine (getEngine) — never a second store —
// but renders a file/icon browser surface (grid of typed tiles or a detail
// list), NOT a tabular grid. Sorting/filtering push to SQL in the engine.
//
// Selecting a file emits `work-file-select` carrying the file's columns as a flat
// object; wire it to a <work-file>'s attributes to drive an inline preview.
//
// Usage (named source, drive a preview):
//   <work-drive src-name="assets"
//     query="SELECT name, path, type, size, modified, hash FROM assets"
//     name-field="name" path-field="path" type-field="type"
//     size-field="size" modified-field="modified" hash-field="hash"
//     view="grid" sort="modified" dir="desc" searchable></work-drive>
//
// Attributes:
//   src-name        a source registered via getEngine().register(...)
//   query           full SQL over the source (default SELECT * over src-name)
//   name-field      column shown as the file name        (default "name")
//   path-field      column with the path / content key   (default "path")
//   type-field      column with the mime/type or ext     (default "type")
//   size-field      column with the byte size            (default "size")
//   modified-field  column with the modified timestamp   (default "modified")
//   hash-field      column with the content-hash         (default "hash")
//   sort            initial sort column (one of the fields above)
//   dir             initial sort direction asc | desc    (default "asc")
//   searchable      show a filter box (filters IN the engine via WHERE … LIKE)
//   selected        the path/key of the currently active file (reflected)
//   view            grid | list                          (variant)
//   variant         framed | bare                        (visual shell)
//
// Events:
//   work-drive-ready  { detail: { rowCount, columns, types, engine } }
//   work-file-select  { detail: { file, index } }   file = flat {col:value}
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import { fileKind, kindGlyph, fmtBytes, fmtWhen, extOf } from "./file-types.js";

const VARIANTS = defineVariants({
  view: { options: ["grid", "list"], default: "grid" },
  variant: { options: ["framed", "bare"], default: "framed" },
});

export class WbDrive extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "src-name", "query", "name-field", "path-field", "type-field",
    "size-field", "modified-field", "hash-field", "sort", "dir",
    "searchable", "selected",
  ];

  // The element reads its state via this.attr() in render() and drives its own
  // repaints (requestUpdate / _load) from attributeChangedCallback — so it must
  // observe every prop attribute itself.
  static get observedAttributes() { return this.props; }

  static styles = css`
    :host { display: block; font-family: var(--wb-font); color: var(--wb-fg); }
    .shell { border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); overflow: hidden; box-shadow: var(--wb-shadow-sm); }
    :host([variant="bare"]) .shell { border: none; box-shadow: none; background: transparent; }

    .toolbar { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3); border-bottom: 1px solid var(--wb-border);
      background: var(--wb-surface-soft); }
    .grow { flex: 1; }
    .search { font: inherit; font-size: var(--wb-text-sm); color: var(--wb-fg);
      background: var(--wb-surface); border: 1px solid var(--wb-border); border-radius: var(--wb-radius-sm);
      padding: var(--wb-space-1) var(--wb-space-2); min-width: 150px; }
    .search:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); border-color: var(--wb-brand); }
    .sort { font: inherit; font-size: var(--wb-text-sm); color: var(--wb-fg);
      background: var(--wb-surface); border: 1px solid var(--wb-border); border-radius: var(--wb-radius-sm);
      padding: var(--wb-space-1) var(--wb-space-2); cursor: pointer; }
    .vbtn { display: inline-flex; gap: 1px; border: 1px solid var(--wb-border); border-radius: var(--wb-radius-sm); overflow: hidden; }
    .vbtn button { appearance: none; cursor: pointer; border: none; background: var(--wb-surface);
      color: var(--wb-fg-muted); font: 600 var(--wb-text-sm)/1 var(--wb-font); padding: var(--wb-space-1) var(--wb-space-2); }
    .vbtn button[aria-pressed="true"] { background: var(--wb-brand-soft); color: var(--wb-brand); }
    .meta { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }

    /* grid of file tiles */
    .grid { max-height: var(--wb-drive-max-h, 460px); overflow: auto;
      padding: var(--wb-space-3); display: grid; gap: var(--wb-space-3);
      grid-template-columns: repeat(auto-fill, minmax(132px, 1fr)); }

    .tile { text-align: center; cursor: pointer; font: inherit; color: var(--wb-fg);
      border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); padding: var(--wb-space-3) var(--wb-space-2);
      display: flex; flex-direction: column; align-items: center; gap: var(--wb-space-2);
      transition: border-color var(--wb-dur) var(--wb-ease), box-shadow var(--wb-dur) var(--wb-ease), transform var(--wb-dur) var(--wb-ease); }
    .tile:hover { border-color: var(--wb-border-strong); transform: translateY(-1px); box-shadow: var(--wb-shadow-sm); }
    .tile[aria-selected="true"] { border-color: var(--wb-brand); box-shadow: 0 0 0 1px var(--wb-brand), var(--wb-shadow-sm); background: var(--wb-brand-soft); }
    .tile:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }

    .icon { width: 48px; height: 48px; display: grid; place-items: center;
      border-radius: var(--wb-radius-sm); font-size: 22px; line-height: 1;
      background: var(--wb-surface-soft); color: var(--wb-fg-muted); }
    .icon[data-kind="image"]  { background: var(--wb-chip-lavender); color: var(--wb-brand-ink); }
    .icon[data-kind="video"]  { background: var(--wb-chip-peach);    color: var(--wb-brand-ink); }
    .icon[data-kind="audio"]  { background: var(--wb-chip-green);    color: var(--wb-brand-ink); }
    .icon[data-kind="text"]   { background: var(--wb-chip-blue);     color: var(--wb-brand-ink); }
    .ext { font-family: var(--wb-font-mono); font-size: 9px; letter-spacing: .04em;
      text-transform: uppercase; opacity: .8; margin-top: 2px; }
    .name { font-size: var(--wb-text-sm); font-weight: 600; max-width: 100%;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sub { font-family: var(--wb-font-mono); font-size: 10px; color: var(--wb-fg-subtle); }

    /* list / detail rows */
    .rows { max-height: var(--wb-drive-max-h, 460px); overflow: auto; }
    .head, .row { display: grid;
      grid-template-columns: 1.6fr .7fr .7fr 1fr; align-items: center;
      gap: var(--wb-space-3); padding: var(--wb-space-2) var(--wb-space-3); }
    .head { position: sticky; top: 0; background: var(--wb-surface-soft);
      border-bottom: 1px solid var(--wb-border); font-family: var(--wb-font-mono);
      font-size: 10px; text-transform: uppercase; letter-spacing: .05em; color: var(--wb-fg-subtle); }
    .row { cursor: pointer; border-bottom: 1px solid var(--wb-border);
      transition: background var(--wb-dur) var(--wb-ease); }
    .row:hover { background: var(--wb-surface-soft); }
    .row[aria-selected="true"] { background: var(--wb-brand-soft); }
    .row:focus-visible { outline: none; box-shadow: inset 0 0 0 2px var(--wb-ring); }
    .cell-name { display: flex; align-items: center; gap: var(--wb-space-2); min-width: 0; }
    .ricon { width: 26px; height: 26px; flex: none; display: grid; place-items: center;
      border-radius: var(--wb-radius-sm); font-size: 14px; background: var(--wb-surface-soft); color: var(--wb-fg-muted); }
    .ricon[data-kind="image"]  { background: var(--wb-chip-lavender); color: var(--wb-brand-ink); }
    .ricon[data-kind="video"]  { background: var(--wb-chip-peach);    color: var(--wb-brand-ink); }
    .ricon[data-kind="audio"]  { background: var(--wb-chip-green);    color: var(--wb-brand-ink); }
    .ricon[data-kind="text"]   { background: var(--wb-chip-blue);     color: var(--wb-brand-ink); }
    .rname { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .num { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); color: var(--wb-fg-muted); }

    .foot { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3); border-top: 1px solid var(--wb-border);
      font-size: var(--wb-text-sm); color: var(--wb-fg-subtle); }
    .engine { display: inline-flex; align-items: center; gap: var(--wb-space-1); }
    .dot { width: 7px; height: 7px; border-radius: var(--wb-radius-pill); background: var(--wb-brand);
      box-shadow: 0 0 0 3px var(--wb-brand-soft); }
    .engine[data-tier="memory"] .dot { background: var(--wb-warn); box-shadow: 0 0 0 3px rgba(184,134,27,0.18); }
    .engine[data-tier="error"] .dot { background: var(--wb-err); box-shadow: none; }
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
    }
    super.connectedCallback();
    this._load();
    this._connected = true;
  }

  attributeChangedCallback(name, old, val) {
    // Reads state via this.attr() in render() and drives its own repaints — does
    // NOT delegate to Lit's attributeChangedCallback (unused property machinery).
    if (!this._connected) return;
    if (name === "src-name" || name === "query" || name === "sort" || name === "dir") this._load();
    else this.requestUpdate(); // view (grid/list markup), selected (aria), variant → repaint
  }

  // ── field resolution ────────────────────────────────────────────────────────
  _f(attr, dflt) {
    const v = this.attr(attr);
    if (v && this._has(v)) return v;
    if (this._has(dflt)) return dflt;
    return null;
  }
  _has(col) { return !!this._result && this._result.columns.includes(col); }
  _nameCol() { return this._f("name-field", "name") || (this._result?.columns[0]); }
  _pathCol() { return this._f("path-field", "path") || this._nameCol(); }
  _typeCol() { return this._f("type-field", "type"); }
  _sizeCol() { return this._f("size-field", "size"); }
  _modCol()  { return this._f("modified-field", "modified"); }
  _hashCol() { return this._f("hash-field", "hash"); }

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
      this._emit("work-drive-ready", {
        rowCount: this._result?.rowCount || 0,
        columns: this._result?.columns || [],
        types: this._result?.types || [],
        engine: this._tier,
      });
    } while (this._loadAgain);
    this._loading = false;
  }

  async _run() {
    this._result = await this._engine.query(this._buildSql());
    this._tier = this._result.engine || this._engine.provider();
  }

  _buildSql() {
    const base = this.attr("query");
    const name = this.attr("src-name");
    const from = base ? `(${base.replace(/;$/, "")}) AS _q` : ident(name || "");
    let sql = `SELECT * FROM ${from}`;
    if (this._filter) {
      const f = this._filter.replace(/'/g, "''");
      // filter on the name + path + type fields (whatever exist on the result)
      const cols = [this.attr("name-field") || "name", this.attr("path-field") || "path", this.attr("type-field") || "type"]
        .filter((c, i, a) => c && a.indexOf(c) === i);
      const ors = cols.map((c) => `CAST(${ident(c)} AS VARCHAR) LIKE '%${f}%'`);
      if (ors.length) sql = `SELECT * FROM (${sql}) AS _s WHERE ${ors.join(" OR ")}`;
    }
    const sort = this.attr("sort");
    if (sort) {
      const dir = (this.attr("dir") || "asc").toLowerCase() === "desc" ? "DESC" : "ASC";
      sql = `SELECT * FROM (${sql}) AS _o ORDER BY ${ident(sort)} ${dir}`;
    }
    return sql;
  }

  // ── render ──────────────────────────────────────────────────────────────────
  render() {
    const searchable = this.boolAttr("searchable");
    const tierText = this._busy ? "querying…" : this._error ? "engine error" :
      this._tier === "runtime" ? "engine: runtime SQLite (VFS)" :
      this._tier === "sqlite-wasm" ? "engine: sqlite-wasm (in-page)" :
      "engine: in-JS (offline)";
    return html`<div class="shell">
      <div class="toolbar">
        ${searchable ? html`<input class="search" type="search" placeholder="Filter files…"
          aria-label="Filter files" .value=${this._filter} @input=${this._onSearch} />` : null}
        ${this._renderSort()}
        <span class="grow"></span>
        <div class="vbtn" role="group" aria-label="view">
          <button class="vg" aria-pressed=${String(this.attr("view") !== "list")}
            title="Grid view" @click=${() => this.setAttribute("view", "grid")}>▦</button>
          <button class="vl" aria-pressed=${String(this.attr("view") === "list")}
            title="List view" @click=${() => this.setAttribute("view", "list")}>☰</button>
        </div>
        <span class="meta">${this._result ? this._result.rowCount.toLocaleString() + " files" : ""}</span>
      </div>
      ${this._renderBody()}
      <div class="foot">
        <span class="engine" data-tier=${this._error ? "error" : this._tier}><span class="dot"></span></span>
        <span>${tierText}</span><span class="grow"></span>
        <span class="meta">content-addressed index · files = rows</span>
      </div></div>`;
  }

  _renderSort() {
    const opts = [
      ["", "Sort…"], ["name", "Name"], ["type", "Type"],
      ["size", "Size"], ["modified", "Modified"],
    ].filter(([v]) => !v || this._fieldFor(v));
    const cur = this.attr("sort") || "";
    return html`<select class="sort" title="Sort by" aria-label="Sort by" @change=${this._onSort}>
      ${opts.map(([v, l]) => html`<option value=${v} ?selected=${v === cur}>${l}</option>`)}
    </select>`;
  }
  _onSort(e) {
    const v = e.target.value;
    if (v) { this.setAttribute("sort", v); } else { this.removeAttribute("sort"); this._load(); }
  }
  // map a logical sort key to the configured column (default = same name)
  _fieldFor(key) {
    const map = { name: this.attr("name-field") || "name", type: this.attr("type-field") || "type",
      size: this.attr("size-field") || "size", modified: this.attr("modified-field") || "modified" };
    const col = map[key];
    return this._has(col) ? col : null;
  }

  _renderBody() {
    if (this._busy && !this._result) return html`<div class="empty">Loading…</div>`;
    if (this._error) return html`<div class="empty">Could not load — ${this._error}</div>`;
    const r = this._result;
    if (!r || !r.rows.length) return html`<div class="empty">${this._filter ? "No matching files." : "No files."}</div>`;
    return this.attr("view") === "list" ? this._renderList() : this._renderGrid();
  }

  _files() {
    const r = this._result;
    const idx = (c) => (c == null ? -1 : r.columns.indexOf(c));
    const nC = idx(this._nameCol()), pC = idx(this._pathCol()), tC = idx(this._typeCol());
    const sC = idx(this._sizeCol()), mC = idx(this._modCol()), hC = idx(this._hashCol());
    return r.rows.map((row, i) => {
      const file = {};
      r.columns.forEach((c, j) => (file[c] = row[j]));
      const name = nC >= 0 ? row[nC] : (pC >= 0 ? row[pC] : "");
      const path = pC >= 0 ? row[pC] : name;
      const type = tC >= 0 ? row[tC] : "";
      return {
        i, file, name: name ?? "", path: path ?? "", type: type ?? "",
        size: sC >= 0 ? row[sC] : null, modified: mC >= 0 ? row[mC] : null,
        hash: hC >= 0 ? row[hC] : null, kind: fileKind(type, name),
      };
    });
  }

  _renderGrid() {
    const selected = this.attr("selected");
    const tiles = this._files().map((f) => {
      const sel = selected != null && String(f.path) === String(selected);
      const ext = extOf(f.name) || extOf(f.type);
      return html`<button class="tile" role="option" aria-selected=${String(sel)}
        data-i=${f.i} data-path=${f.path}
        @click=${() => this._select(f.i)} @keydown=${(e) => this._onKey(e, f.i)}>
        <span class="icon" data-kind=${f.kind}>${kindGlyph(f.kind)}${ext ? html`<span class="ext">${ext}</span>` : null}</span>
        <span class="name" title=${f.name}>${f.name || "—"}</span>
        <span class="sub">${f.size != null ? fmtBytes(f.size) : f.kind}</span>
      </button>`;
    });
    return html`<div class="grid" role="listbox">${tiles}</div>`;
  }

  _renderList() {
    const selected = this.attr("selected");
    const rows = this._files().map((f) => {
      const sel = selected != null && String(f.path) === String(selected);
      return html`<div class="row" role="option" tabindex="0" aria-selected=${String(sel)}
        data-i=${f.i} data-path=${f.path}
        @click=${() => this._select(f.i)} @keydown=${(e) => this._onKey(e, f.i)}>
        <span class="cell-name">
          <span class="ricon" data-kind=${f.kind}>${kindGlyph(f.kind)}</span>
          <span class="rname" title=${f.name}>${f.name || "—"}</span>
        </span>
        <span class="num">${f.type || f.kind}</span>
        <span class="num">${f.size != null ? fmtBytes(f.size) : "—"}</span>
        <span class="num">${f.modified != null ? fmtWhen(f.modified) : "—"}</span>
      </div>`;
    });
    return html`<div class="rows" role="listbox">
      <div class="head"><span>Name</span><span>Type</span><span>Size</span><span>Modified</span></div>
      ${rows}</div>`;
  }

  // ── interaction ─────────────────────────────────────────────────────────────
  // Debounced search: filters IN the engine, then re-renders. Lit's surgical
  // update keeps the live <input> (and its focus/caret) intact across re-renders.
  _onSearch(e) {
    const value = e.target.value;
    clearTimeout(this._t);
    this._t = setTimeout(() => { this._filter = value; this._run().then(() => this.requestUpdate()); }, 140);
  }

  _onKey(e, i) {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); this._select(i); }
  }

  _select(i) {
    const f = this._files().find((x) => x.i === i);
    if (!f) return;
    this.setAttribute("selected", f.path == null ? "" : String(f.path));
    this._emit("work-file-select", { file: f.file, index: i });
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }

define("work-drive", WbDrive);
