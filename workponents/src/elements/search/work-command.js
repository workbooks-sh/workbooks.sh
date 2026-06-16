// <work-command> — the ⌘K command palette. THE killer element. A keyboard-driven,
// grouped, themed overlay that ranks over TWO sources at once:
//   1. a COMMAND SET (provided via the `.commands` property or <work-command-item>
//      slots) — fuzzy-ranked IN-WASM by ./rank.js (subsequence + bonuses). This is
//      the in-memory ranking the engine's LIKE can't express (ordered relevance,
//      highlight ranges). Commands map to Dock capabilities / app actions.
//   2. DATA RESULTS from the shared engine (optional `src-name`/`query`/`fields`) —
//      each keystroke runs a debounced engine query, exactly like <work-search>:
//      search IS a query. Reach compute ONLY through src/data (getEngine).
//
// Open with ⌘K / Ctrl-K (auto-bound while connected) or programmatically via
// .open(); close with Escape / backdrop click / select. Results are grouped
// (Commands · the data source) with arrow-key navigation crossing groups.
//
// Properties / attributes:
//   .commands = [{ id, label, hint?, group?, keywords?, icon?, run?() }]   (property)
//   <work-command-item id label hint group keywords>   declarative command slots
//   src-name / query / fields / data-label   optional engine-backed data group
//   data-limit       max data rows (default 6)
//   placeholder      input placeholder
//   hotkey           "mod+k" (default) | "ctrl+k" | "none"   global open hotkey
//   trigger          CSS selector of element(s) that open the palette on click
//   variant          center | top
//
// Events:
//   work-command-open    {}
//   work-command-close   {}
//   work-command-query   { detail: { sql, rowCount, engine, value } }
//   work-command-select  { detail: { kind:"command"|"data", item, row?, index } }
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import { fuzzyScore, highlight } from "./rank.js";
import { ref, createRef } from "lit/directives/ref.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";

const VARIANTS = defineVariants({
  variant: { options: ["center", "top"], default: "center" },
});

export class WorkCommand extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "src-name", "query", "fields", "data-label", "data-limit", "placeholder", "open"];

  static styles = css`
    :host { position: fixed; inset: 0; z-index: 1000; display: none; font-family: var(--work-font); color: var(--work-fg); }
    :host([open]) { display: block; }
    .backdrop { position: absolute; inset: 0; background: var(--work-scrim-soft); backdrop-filter: blur(2px);
      animation: fade var(--work-dur) var(--work-ease); }
    @keyframes fade { from { opacity: 0; } }
    .dialog { position: absolute; left: 50%; transform: translateX(-50%); width: min(620px, 92vw);
      background: var(--work-surface); border: 1px solid var(--work-border); border-radius: var(--work-radius-lg);
      box-shadow: var(--work-shadow); overflow: hidden; animation: pop var(--work-dur) var(--work-ease); }
    :host([variant="center"]) .dialog { top: 18vh; }
    :host([variant="top"]) .dialog { top: 8vh; }
    @keyframes pop { from { opacity: 0; transform: translate(-50%, 6px); } }

    .field { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-3) var(--work-space-4); border-bottom: 1px solid var(--work-border); }
    .icon { width: 18px; height: 18px; color: var(--work-fg-subtle); flex: none; }
    input { flex: 1; min-width: 0; font: inherit; font-size: var(--work-text-lg); color: var(--work-fg);
      background: transparent; border: none; outline: none; }
    input::placeholder { color: var(--work-fg-subtle); }
    .kbd { font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-subtle);
      border: 1px solid var(--work-border); border-radius: var(--work-radius-sm); padding: var(--work-space-px) var(--work-space-6px); flex: none; }
    .spin { width: 14px; height: 14px; border-radius: var(--work-radius-pill); flex: none;
      border: 2px solid var(--work-border-strong); border-top-color: var(--work-brand); animation: spin .7s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }

    .list { list-style: none; margin: 0; padding: var(--work-space-2); max-height: 52vh; overflow: auto; }
    .group { font-family: var(--work-font-mono); font-size: var(--work-text-2xs); letter-spacing: .16em; text-transform: uppercase;
      color: var(--work-fg-subtle); padding: var(--work-space-3) var(--work-space-3) var(--work-space-1); }
    .item { display: flex; align-items: center; gap: var(--work-space-3); padding: var(--work-space-2) var(--work-space-3);
      border-radius: var(--work-radius-sm); cursor: pointer; }
    .item[aria-selected="true"] { background: var(--work-brand-soft); }
    .item .ic { width: 18px; text-align: center; color: var(--work-fg-muted); flex: none; font-size: var(--work-text-icon); }
    .item .label { flex: 1; min-width: 0; font-size: var(--work-text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .item .hint { font-size: var(--work-text-sm); color: var(--work-fg-subtle); white-space: nowrap; flex: none; }
    .item[aria-selected="true"] .hint { color: var(--work-fg-muted); }
    mark { background: var(--work-brand-soft); color: var(--work-brand-ink, var(--work-fg)); border-radius: var(--work-radius-xs); padding: 0 var(--work-space-px); }
    [data-work-theme="dark"] mark, [data-work-theme="signal"] mark { color: var(--work-brand); }

    .empty { padding: var(--work-space-5) var(--work-space-4); text-align: center; color: var(--work-fg-muted); font-size: var(--work-text-sm); }
    .foot { display: flex; align-items: center; gap: var(--work-space-3); padding: var(--work-space-2) var(--work-space-4);
      border-top: 1px solid var(--work-border); background: var(--work-surface-soft);
      font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-subtle); }
    .foot .k { border: 1px solid var(--work-border); border-radius: var(--work-radius-4px); padding: 0 var(--work-space-5px); color: var(--work-fg-muted); }
    .foot .dot { width: 6px; height: 6px; border-radius: var(--work-radius-pill); background: var(--work-brand); box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .foot[data-tier="memory"] .dot { background: var(--work-warn); box-shadow: 0 0 0 var(--work-space-3px) var(--work-warn-glow); }
    .grow { flex: 1; }
  `;

  _inputRef = createRef();

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._value = "";
      this._commands = [];     // [{ id,label,hint,group,keywords,icon,run }]
      this._dataRows = null;   // WbQueryResult | null
      this._tier = this._engine.provider();
      this._busy = false;
      this._error = null;
      this._active = 0;
      this._flat = [];         // flattened visible entries for keyboard nav
      this._readSlotCommands();
    }
    super.connectedCallback();
    this._bindHotkey();
    this._bindTriggers();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._hk) window.removeEventListener("keydown", this._hk, true);
  }

  // ── command source (property + declarative slot) ─────────────────────────────
  set commands(list) {
    this._commands = (Array.isArray(list) ? list : []).map((c, i) => ({
      id: c.id ?? `cmd_${i}`, label: c.label ?? String(c.id ?? i),
      hint: c.hint ?? "", group: c.group ?? "Commands", icon: c.icon ?? "",
      keywords: c.keywords ?? "", run: typeof c.run === "function" ? c.run : null,
    }));
    if (this._connected) this.requestUpdate();
  }
  get commands() { return this._commands; }

  _readSlotCommands() {
    const items = [...this.querySelectorAll("work-command-item")];
    if (!items.length) return;
    this._commands = items.map((el, i) => ({
      id: el.getAttribute("id") || `cmd_${i}`,
      label: el.getAttribute("label") || el.textContent.trim() || `Command ${i}`,
      hint: el.getAttribute("hint") || "",
      group: el.getAttribute("group") || "Commands",
      icon: el.getAttribute("icon") || "",
      keywords: el.getAttribute("keywords") || "",
      run: null,
      _el: el,
    }));
  }

  // ── open / close ─────────────────────────────────────────────────────────────
  open() {
    this.setAttribute("open", "");
    this._value = "";
    this._dataRows = null;
    this._active = 0;
    this._emit("work-command-open", {});
    this.requestUpdate();
    requestAnimationFrame(() => this._inputRef.value?.focus());
  }
  close() {
    this.removeAttribute("open");
    this._emit("work-command-close", {});
    this.requestUpdate();
  }
  toggle() { (this.hasAttribute("open") ? this.close() : this.open()); }

  _bindHotkey() {
    const hk = (this.attr("hotkey", "mod+k") || "mod+k").toLowerCase();
    if (hk === "none") return;
    const wantCtrl = hk.includes("ctrl");
    this._hk = (e) => {
      const key = (e.key || "").toLowerCase();
      const mod = wantCtrl ? e.ctrlKey : (e.metaKey || e.ctrlKey);
      if (mod && key === "k") { e.preventDefault(); this.toggle(); }
    };
    window.addEventListener("keydown", this._hk, true);
  }

  _bindTriggers() {
    const sel = this.attr("trigger");
    if (!sel) return;
    document.querySelectorAll(sel).forEach((el) =>
      el.addEventListener("click", () => this.open()));
  }

  // ── data group (engine-backed; search IS a query) ────────────────────────────
  _hasData() { return this.hasAttribute("src-name") || this.hasAttribute("query"); }

  _fields() {
    const f = this.attr("fields");
    return f ? f.split(",").map((s) => s.trim()).filter(Boolean) : null;
  }

  async _resolveDataFields() {
    if (this._dataFields) return;
    const declared = this._fields();
    if (declared) { this._dataFields = declared; return; }
    const from = this._dataFrom();
    try {
      const probe = await this._engine.query(`SELECT * FROM ${from} LIMIT 1`);
      this._dataFields = probe.columns.filter((c, j) => probe.types[j] === "string" || probe.types[j] == null);
      if (!this._dataFields.length) this._dataFields = probe.columns;
    } catch { this._dataFields = []; }
  }

  _dataFrom() {
    const base = this.attr("query");
    return base ? `(${base.replace(/;$/, "")}) AS _q` : ident(this.attr("src-name"));
  }

  async _runData() {
    if (!this._hasData() || !this._value) { this._dataRows = null; this.requestUpdate(); return; }
    // Single-flight, last-wins across debounced keystrokes.
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._busy = true; this._error = null; this.requestUpdate();
      try {
        if (this.hasAttribute("src-name")) await this._engine.whenRegistered(this.attr("src-name"));
        await this._resolveDataFields();
        const limit = parseInt(this.attr("data-limit", "6"), 10) || 6;
        const term = this._value.replace(/'/g, "''");
        // SQLite LIKE is case-insensitive for ASCII on every tier — no provider fork.
        let sql = `SELECT * FROM ${this._dataFrom()}`;
        if (this._dataFields.length) {
          const ors = this._dataFields.map((c) => `CAST(${ident(c)} AS VARCHAR) LIKE '%${term}%'`);
          sql += ` WHERE ${ors.join(" OR ")}`;
        }
        sql += ` LIMIT ${limit}`;
        this._dataRows = await this._engine.query(sql);
        this._tier = this._dataRows.engine || this._engine.provider();
        this._emit("work-command-query", { sql, rowCount: this._dataRows.rowCount, engine: this._tier, value: this._value });
      } catch (e) {
        this._error = String((e && e.message) || e);
        this._dataRows = null;
      }
      this._busy = false;
      this.requestUpdate();
    } while (this._loadAgain);
    this._loading = false;
  }

  // ── build the visible, grouped, ranked entry list ────────────────────────────
  _build() {
    const groups = [];   // [{ name, entries:[{kind, ...}] }]
    // 1 · commands — fuzzy-ranked in-WASM. Score against the LABEL (so highlight
    // ranges map onto the displayed text); fall back to a keyword hit (no
    // highlight) so a command surfaces on a synonym its label doesn't contain.
    const q = String(this._value || "").trim();
    const scored = [];
    for (const item of this._commands) {
      const onLabel = fuzzyScore(q, item.label);
      if (onLabel) { scored.push({ item, score: onLabel.score, ranges: onLabel.ranges }); continue; }
      if (q && item.keywords && fuzzyScore(q, item.keywords)) scored.push({ item, score: -50, ranges: [] });
      else if (!q) scored.push({ item, score: 0, ranges: [] });
    }
    scored.sort((a, b) => b.score - a.score);
    const byGroup = new Map();
    for (const { item, ranges } of scored) {
      const g = item.group || "Commands";
      if (!byGroup.has(g)) byGroup.set(g, []);
      byGroup.get(g).push({ kind: "command", item, label: item.label, ranges });
    }
    for (const [name, entries] of byGroup) groups.push({ name, entries });
    // 2 · data — engine results (already filtered by the query)
    if (this._hasData() && this._dataRows && this._dataRows.rows.length) {
      const r = this._dataRows;
      const fields = this._dataFields || r.columns;
      const titleCol = fields[0] || r.columns[0];
      const ti = r.columns.indexOf(titleCol);
      const entries = r.rows.map((row, i) => ({
        kind: "data", row, index: i,
        label: String(ti >= 0 ? row[ti] : row[0] ?? ""),
        hint: r.columns.length > 1 ? String(row[(ti + 1) % r.columns.length] ?? "") : "",
      }));
      groups.push({ name: this.attr("data-label", "Results"), entries });
    }
    // flatten for keyboard nav
    this._flat = [];
    for (const g of groups) for (const e of g.entries) this._flat.push(e);
    if (this._active >= this._flat.length) this._active = Math.max(0, this._flat.length - 1);
    return groups;
  }

  // ── render ──────────────────────────────────────────────────────────────────
  render() {
    if (!this.hasAttribute("open")) return "";
    const groups = this._build();
    const ph = this.attr("placeholder", "Type a command or search…");
    const tierText = this._error ? "engine error" :
      this._tier === "runtime" ? "runtime" : this._tier === "duckdb-wasm" ? "duckdb-wasm" : "in-JS";
    let flatI = 0;
    const body = groups.length
      ? groups.map((g) => {
          const items = g.entries.map((e) => {
            const i = flatI++;
            const labelHtml = e.kind === "command"
              ? highlight(e.label, e.ranges)
              : highlightTerm(e.label, this._value);
            const ic = e.kind === "command" ? (e.item.icon || "") : "›";
            return html`<li class="item" role="option" aria-selected=${String(i === this._active)} data-i=${i}
              @mousedown=${(ev) => { ev.preventDefault(); this._run(i); }}
              @mousemove=${() => { if (i !== this._active) { this._active = i; this._syncActive(); } }}>
              <span class="ic">${ic}</span>
              <span class="label">${unsafeHTML(labelHtml)}</span>
              ${e.hint || (e.item && e.item.hint) ? html`<span class="hint">${e.hint || e.item.hint}</span>` : ""}
            </li>`;
          });
          return html`<li class="group">${g.name}</li>${items}`;
        })
      : html`<li class="empty">${this._error ? this._error : this._value ? html`No results for “${this._value}”.` : "Type to search commands and data."}</li>`;

    return html`
      <div class="backdrop" part="backdrop" @mousedown=${() => this.close()}></div>
      <div class="dialog" role="dialog" aria-modal="true" aria-label="Command palette">
        <div class="field">
          <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
            <circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line>
          </svg>
          <input ${ref(this._inputRef)} type="text" role="combobox" aria-expanded="true" aria-label="Command palette"
            placeholder=${ph} .value=${this._value} autocomplete="off" spellcheck="false"
            @focus=${() => { this._inputFocused = true; }} @blur=${() => { this._inputFocused = false; }}
            @input=${this._onInput} @keydown=${this._onKey} />
          ${this._busy ? html`<span class="spin" aria-hidden="true"></span>` : html`<span class="kbd">esc</span>`}
        </div>
        <ul class="list" role="listbox">${body}</ul>
        <div class="foot" data-tier=${this._error ? "error" : this._tier}>
          <span class="k">↑↓</span><span>navigate</span>
          <span class="k">↵</span><span>select</span>
          <span class="grow"></span>
          ${this._hasData() ? html`<span class="dot"></span><span>engine: ${tierText}</span>` : ""}
        </div>
      </div>`;
  }

  // Restore focus + caret after a surgical re-render while open + focused.
  updated() {
    if (!this.hasAttribute("open")) return;
    const input = this._inputRef.value;
    if (input && this._inputFocused && this.shadowRoot.activeElement !== input) {
      input.focus();
      const e = input.value.length;
      input.setSelectionRange(e, e);
    }
  }

  _onInput = (e) => {
    this._value = e.target.value;
    this._active = 0;
    clearTimeout(this._t);
    this._t = setTimeout(() => this._runData(), 140);
    this.requestUpdate();   // commands re-rank instantly; data follows when the query resolves
  };

  _onKey(e) {
    const n = this._flat.length;
    if (e.key === "ArrowDown") { e.preventDefault(); if (n) { this._active = (this._active + 1) % n; this._syncActive(); } }
    else if (e.key === "ArrowUp") { e.preventDefault(); if (n) { this._active = (this._active - 1 + n) % n; this._syncActive(); } }
    else if (e.key === "Enter") { if (n) { e.preventDefault(); this._run(this._active); } }
    else if (e.key === "Escape") { e.preventDefault(); this.close(); }
  }

  _syncActive() {
    const items = this.shadowRoot.querySelectorAll(".item[data-i]");
    items.forEach((li) => {
      const sel = +li.getAttribute("data-i") === this._active;
      li.setAttribute("aria-selected", String(sel));
      if (sel) li.scrollIntoView({ block: "nearest" });
    });
  }

  _run(i) {
    const e = this._flat[i];
    if (!e) return;
    if (e.kind === "command") {
      this._emit("work-command-select", { kind: "command", item: e.item, index: i });
      if (e.item.run) try { e.item.run(e.item); } catch (err) { console.error("[work-command] run failed", err); }
      if (e.item._el) e.item._el.dispatchEvent(new CustomEvent("select", { bubbles: true, composed: true, detail: { item: e.item } }));
    } else {
      const r = this._dataRows;
      const obj = {};
      r.columns.forEach((c, j) => (obj[c] = r.rows[e.index][j]));
      this._emit("work-command-select", { kind: "data", row: obj, index: e.index, item: obj });
    }
    this.close();
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
function highlightTerm(text, term) {
  const t = String(text ?? ""), q = String(term ?? "").trim();
  if (!q) return esc(t);
  const idx = t.toLowerCase().indexOf(q.toLowerCase());
  if (idx < 0) return esc(t);
  return highlight(t, [[idx, idx + q.length]]);
}

// A lightweight declarative slot for command authoring (<work-command-item …>).
class WorkCommandItem extends HTMLElement {
  connectedCallback() { this.style.display = "none"; }
}
define("work-command-item", WorkCommandItem);
define("work-command", WorkCommand);
