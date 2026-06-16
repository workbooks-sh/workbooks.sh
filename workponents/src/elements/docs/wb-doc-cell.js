// <work-doc-cell> — a live computed block inside a document. THE differentiator:
// the block that renders the data also computes it. A cell carries its query as
// source (preview ≡ source); it reaches an engine through the Dock seam
// (`this.host`) — DuckDB-wasm / Polars / the OQL kernel resolved local | runtime
// | kernel per platform-model. When no engine is reachable it degrades cleanly
// to a "computed" preview with sample output (the same shape a real run returns),
// so the document is never broken by an absent capability.
//
// Usage (standalone): <work-doc-cell lang="sql">SELECT region, sum(rev) ...</work-doc-cell>
// Or, embedded by <work-doc> from a fenced ```sql block in the source.
import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

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

  static styles = css`
    :host { display: block; margin: 1.1em 0; }
    .cell { border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-surface); overflow: hidden; box-shadow: var(--work-shadow-sm); }
    :host([variant="inline"]) .cell { border: none; box-shadow: none; background: transparent; }

    .head { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-3); border-bottom: 1px solid var(--work-border);
      background: var(--work-surface-soft); font-family: var(--work-font-mono); font-size: var(--work-text-sm); }
    :host([variant="inline"]) .head { background: transparent; padding-left: 0; padding-right: 0; }
    .lang { font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--work-brand); }
    .title { color: var(--work-fg); font-family: var(--work-font); font-weight: 600; }
    .status { margin-left: auto; display: inline-flex; align-items: center; gap: var(--work-space-1);
      font-size: 0.85em; color: var(--work-fg-muted); }
    .dot { width: 7px; height: 7px; border-radius: var(--work-radius-pill); background: var(--work-brand);
      box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .status[data-state="stub"] .dot { background: var(--work-warn); box-shadow: 0 0 0 var(--work-space-3px) var(--work-warn-glow); }
    .status[data-state="error"] .dot { background: var(--work-err); box-shadow: none; }

    .query { margin: 0; padding: var(--work-space-3); font-family: var(--work-font-mono);
      font-size: var(--work-text-sm); line-height: 1.55; color: var(--work-fg-muted);
      background: var(--work-bg); border-bottom: 1px solid var(--work-border); white-space: pre-wrap; word-break: break-word; }
    :host([variant="inline"]) .query { background: var(--work-surface-soft); border-radius: var(--work-radius-sm); border: none; }

    .out { padding: var(--work-space-3); font-family: var(--work-font); }

    table { width: 100%; border-collapse: collapse; font-size: var(--work-text-sm); }
    th, td { text-align: left; padding: var(--work-space-2) var(--work-space-3); border-bottom: 1px solid var(--work-border); }
    th { font-weight: 600; color: var(--work-fg-muted); font-family: var(--work-font-mono); font-size: 0.85em;
      text-transform: uppercase; letter-spacing: 0.04em; }
    tbody tr:last-child td { border-bottom: none; }
    tbody tr:hover { background: var(--work-surface-soft); }
    td:not(:first-child) { font-variant-numeric: tabular-nums; }

    .metric { display: flex; align-items: baseline; gap: var(--work-space-3); }
    .metric .v { font-family: var(--work-font-display, var(--work-font)); font-size: 2.4em; font-weight: 600;
      letter-spacing: -0.02em; color: var(--work-fg); line-height: 1; }
    .metric .l { color: var(--work-fg-muted); font-size: var(--work-text-sm); }
    .metric .d { margin-left: auto; color: var(--work-ok); font-weight: 600; font-size: var(--work-text-sm); }

    .foot { padding: var(--work-space-2) var(--work-space-3); border-top: 1px solid var(--work-border);
      font-size: var(--work-text-sm); color: var(--work-fg-subtle); display: flex; gap: var(--work-space-2); align-items: center; }
    .recompute { cursor: pointer; color: var(--work-brand); border: none; background: none; font: inherit;
      font-family: var(--work-font-mono); padding: 0; }
    .recompute:hover { text-decoration: underline; }
    pre.raw { margin: 0; font-family: var(--work-font-mono); font-size: var(--work-text-sm); }
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
    this.requestUpdate();
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
    this.requestUpdate();
  }

  _renderResult() {
    const r = this._result || {};
    const display = this.attr("display") || (r.kind === "metric" ? "metric" : "table");
    if (display === "raw") {
      return html`<pre class="raw">${JSON.stringify(r, null, 2)}</pre>`;
    }
    if (r.kind === "metric" || display === "metric") {
      return html`<div class="metric"><span class="v">${r.value ?? "—"}</span><span class="l">${r.label ?? ""}</span>${r.delta ? html`<span class="d">${r.delta}</span>` : ""}</div>`;
    }
    const cols = r.columns || [];
    const rows = r.rows || [];
    return html`<table><thead><tr>${cols.map((c) => html`<th>${c}</th>`)}</tr></thead><tbody>${rows.map(
      (row) => html`<tr>${row.map((c) => html`<td>${c}</td>`)}</tr>`,
    )}</tbody></table>`;
  }

  render() {
    const lang = (this.attr("lang", "sql") || "sql").toLowerCase();
    const title = this.attr("title");
    const state = this._error ? "error" : this._live ? "live" : "stub";
    const stateText = this._busy ? "computing…" : this._error ? "compute error" : this._live ? "computed live" : "computed (sample)";
    return html`
      <div class="cell">
        <div class="head">
          <span class="lang">${lang}</span>
          ${title ? html`<span class="title">${title}</span>` : ""}
          <span class="status" data-state=${state}><span class="dot"></span>${stateText}</span>
        </div>
        ${this._source ? html`<pre class="query">${this._source}</pre>` : ""}
        <div class="out">${this._busy ? html`<span style="color:var(--work-fg-muted)">running…</span>` : this._renderResult()}</div>
        <div class="foot">
          <button class="recompute" type="button" @click=${this._compute}>recompute</button>
          <span>·</span>
          <span>${this._live ? "engine: " + (LANG_CAP[lang] || "kernel") : "no engine reached — sample shape shown"}</span>
        </div>
      </div>`;
  }
}

define("work-doc-cell", WbDocCell);
