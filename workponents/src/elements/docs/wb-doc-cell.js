// <wb-doc-cell> — a live computed block inside a document. THE differentiator:
// the block that renders the data also computes it. A cell carries its query as
// source (preview ≡ source); it reaches an engine through the Dock seam
// (`this.host`) — DuckDB-wasm / Polars / the OQL kernel resolved local | runtime
// | kernel per platform-model. When no engine is reachable it degrades cleanly
// to a "computed" preview with sample output (the same shape a real run returns),
// so the document is never broken by an absent capability.
//
// Usage (standalone): <wb-doc-cell lang="sql">SELECT region, sum(rev) ...</wb-doc-cell>
// Or, embedded by <wb-doc> from a fenced ```sql block in the source.
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { escapeHtml } from "./render.js";

const VARIANTS = defineVariants({
  // how the result renders
  display: { options: ["table", "metric", "raw"], default: "table" },
  // visual weight of the cell shell
  variant: { options: ["card", "inline"], default: "card" },
});

// The compute language → which capability backs it (declared, Dock-resolved).
const LANG_CAP = {
  sql: "duckdb", duckdb: "duckdb",
  polars: "duckdb",
  py: "kernel", python: "kernel", js: "kernel", chart: "kernel",
};

// Graceful sample output per language — the SHAPE a real run returns, so the
// document reads correctly offline. (The seed's stub; a live host replaces it.)
function sampleResult(lang, code) {
  // A single scalar aggregate with no GROUP BY reads as a metric; anything that
  // groups/selects multiple columns reads as a table.
  const scalar = /\b(count|sum|avg|min|max)\s*\(/i.test(code) && !/group\s+by/i.test(code);
  if (scalar && lang !== "polars") {
    return { kind: "metric", value: "128,402", label: "orders", delta: "+12.4%" };
  }
  return {
    kind: "table",
    columns: ["region", "orders", "revenue"],
    rows: [
      ["North", "4,182", "$612,400"],
      ["South", "3,907", "$548,210"],
      ["EMEA", "2,640", "$501,880"],
      ["APAC", "1,933", "$377,150"],
    ],
  };
}

export class WbDocCell extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "lang", "src", "title", "state"];

  static styles = `
    :host { display: block; margin: 1.1em 0; }
    .cell { border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); overflow: hidden; box-shadow: var(--wb-shadow-sm); }
    :host([variant="inline"]) .cell { border: none; box-shadow: none; background: transparent; }

    .head { display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3); border-bottom: 1px solid var(--wb-border);
      background: var(--wb-surface-soft); font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); }
    :host([variant="inline"]) .head { background: transparent; padding-left: 0; padding-right: 0; }
    .lang { font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--wb-brand); }
    .title { color: var(--wb-fg); font-family: var(--wb-font); font-weight: 600; }
    .status { margin-left: auto; display: inline-flex; align-items: center; gap: var(--wb-space-1);
      font-size: 0.85em; color: var(--wb-fg-muted); }
    .dot { width: 7px; height: 7px; border-radius: var(--wb-radius-pill); background: var(--wb-brand);
      box-shadow: 0 0 0 3px var(--wb-brand-soft); }
    .status[data-state="stub"] .dot { background: var(--wb-warn); box-shadow: 0 0 0 3px rgba(184,134,27,0.18); }
    .status[data-state="error"] .dot { background: var(--wb-err); box-shadow: none; }

    .query { margin: 0; padding: var(--wb-space-3); font-family: var(--wb-font-mono);
      font-size: var(--wb-text-sm); line-height: 1.55; color: var(--wb-fg-muted);
      background: var(--wb-bg); border-bottom: 1px solid var(--wb-border); white-space: pre-wrap; word-break: break-word; }
    :host([variant="inline"]) .query { background: var(--wb-surface-soft); border-radius: var(--wb-radius-sm); border: none; }

    .out { padding: var(--wb-space-3); font-family: var(--wb-font); }

    table { width: 100%; border-collapse: collapse; font-size: var(--wb-text-sm); }
    th, td { text-align: left; padding: var(--wb-space-2) var(--wb-space-3); border-bottom: 1px solid var(--wb-border); }
    th { font-weight: 600; color: var(--wb-fg-muted); font-family: var(--wb-font-mono); font-size: 0.85em;
      text-transform: uppercase; letter-spacing: 0.04em; }
    tbody tr:last-child td { border-bottom: none; }
    tbody tr:hover { background: var(--wb-surface-soft); }
    td:not(:first-child) { font-variant-numeric: tabular-nums; }

    .metric { display: flex; align-items: baseline; gap: var(--wb-space-3); }
    .metric .v { font-family: var(--wb-font-display, var(--wb-font)); font-size: 2.4em; font-weight: 600;
      letter-spacing: -0.02em; color: var(--wb-fg); line-height: 1; }
    .metric .l { color: var(--wb-fg-muted); font-size: var(--wb-text-sm); }
    .metric .d { margin-left: auto; color: var(--wb-ok); font-weight: 600; font-size: var(--wb-text-sm); }

    .foot { padding: var(--wb-space-2) var(--wb-space-3); border-top: 1px solid var(--wb-border);
      font-size: var(--wb-text-sm); color: var(--wb-fg-subtle); display: flex; gap: var(--wb-space-2); align-items: center; }
    .recompute { cursor: pointer; color: var(--wb-brand); border: none; background: none; font: inherit;
      font-family: var(--wb-font-mono); padding: 0; }
    .recompute:hover { text-decoration: underline; }
  `;

  connectedCallback() {
    // Capture inner source ONCE before the base wipes the shadow root; the cell
    // body is its query (composition-as-source).
    if (this._source == null) {
      const inner = this.textContent.trim();
      this._source = this.attr("src") || inner || "";
    }
    super.connectedCallback();
    this._compute();
  }

  async _compute() {
    const lang = (this.attr("lang", "sql") || "sql").toLowerCase();
    const cap = LANG_CAP[lang] || "kernel";
    this._busy = true;
    this._error = null;
    try {
      if (this.host.available(cap)) {
        // Live path: ask the runtime/kernel to run the cell. The seam exists; a
        // configured Host routes it. (Endpoint contract: POST /docs/cell.)
        const res = await this.host.request("/docs/cell", { body: { lang, source: this._source } });
        this._result = res && res.result ? res.result : sampleResult(lang, this._source);
        this._live = !!(res && res.result);
      } else {
        this._result = sampleResult(lang, this._source);
        this._live = false;
      }
    } catch (e) {
      this._error = String(e.message || e);
      this._result = sampleResult(lang, this._source);
      this._live = false;
    }
    this._busy = false;
    this.update();
  }

  _renderResult() {
    const r = this._result || {};
    const display = this.attr("display") || (r.kind === "metric" ? "metric" : "table");
    if (display === "raw") {
      return `<pre style="margin:0;font-family:var(--wb-font-mono);font-size:var(--wb-text-sm)">${escapeHtml(JSON.stringify(r, null, 2))}</pre>`;
    }
    if (r.kind === "metric" || display === "metric") {
      return `<div class="metric"><span class="v">${escapeHtml(r.value ?? "—")}</span>` +
        `<span class="l">${escapeHtml(r.label ?? "")}</span>` +
        (r.delta ? `<span class="d">${escapeHtml(r.delta)}</span>` : "") + `</div>`;
    }
    const cols = r.columns || [];
    const rows = r.rows || [];
    return `<table><thead><tr>${cols.map((c) => `<th>${escapeHtml(c)}</th>`).join("")}</tr></thead>` +
      `<tbody>${rows.map((row) => `<tr>${row.map((c) => `<td>${escapeHtml(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
  }

  render() {
    const lang = (this.attr("lang", "sql") || "sql").toLowerCase();
    const title = this.attr("title");
    const state = this._error ? "error" : this._live ? "live" : "stub";
    const stateText = this._busy ? "computing…" : this._error ? "compute error" : this._live ? "computed live" : "computed (sample)";
    return `
      <div class="cell">
        <div class="head">
          <span class="lang">${escapeHtml(lang)}</span>
          ${title ? `<span class="title">${escapeHtml(title)}</span>` : ""}
          <span class="status" data-state="${state}"><span class="dot"></span>${stateText}</span>
        </div>
        ${this._source ? `<pre class="query">${escapeHtml(this._source)}</pre>` : ""}
        <div class="out">${this._busy ? '<span style="color:var(--wb-fg-muted)">running…</span>' : this._renderResult()}</div>
        <div class="foot">
          <button class="recompute" type="button">recompute</button>
          <span>·</span>
          <span>${this._live ? "engine: " + (LANG_CAP[lang] || "kernel") : "no engine reached — sample shape shown"}</span>
        </div>
      </div>`;
  }

  update() {
    super.update();
    const btn = this.shadowRoot.querySelector(".recompute");
    if (btn) btn.addEventListener("click", () => this._compute());
  }
}

define("wb-doc-cell", WbDocCell);
