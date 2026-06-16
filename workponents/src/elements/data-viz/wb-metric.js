// <work-metric> — a single KPI, computed in the engine. The number IS a query: the
// element runs a 1-row aggregate on the shared engine and renders one value (+
// optional label, delta, and inline <work-spark> trend). The whole point of the
// reinvention: there is no "metric value" prop you hand-compute in JS — you hand
// it SQL and the engine returns the scalar. Same data contract + engine as
// <work-chart>; reach compute ONLY through src/data.
//
// Re-based onto Lit: render() returns a Lit template wrapping the string-built
// shell via unsafeHTML (the embedded <work-spark> is a sibling custom element).
// The _load single-flight + whenRegistered/register plumbing is unchanged.
//
// Usage (the aggregate runs in the engine, returns one row):
//   <work-metric label="Total revenue" format="usd"
//     query="SELECT sum(revenue) AS total FROM orders"></work-metric>
//
//   <work-metric label="Avg order" format="usd" value-col="avg_order" delta-col="wow"
//     query="SELECT avg(revenue) AS avg_order, 0.082 AS wow FROM orders"></work-metric>
//
// Attributes:
//   query        SQL returning ONE row (the scalar lives here, engine-computed)
//   src-name / rows / csv   — register a source inline (same story as work-chart)
//   value-col    which result column is the value (default: first)
//   delta-col    optional column holding a fraction delta (e.g. 0.082 = +8.2%)
//   label        the metric caption
//   format       usd | num | pct | none
//   size         sm | md | lg
//   variant      card | bare
//   trend        optional SQL for an inline sparkline; renders <work-spark>
//   trend-y      value column for the trend query
//
// Events: work-metric-ready { detail: { value, delta, engine } }
import { WbElement, html, css, define } from "../../core/element.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import "./wb-spark.js";

const VARIANTS = defineVariants({
  size: { options: ["sm", "md", "lg"], default: "md" },
  variant: { options: ["card", "bare"], default: "card" },
});

let _autoId = 0;

export class WbMetric extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "query", "src-name", "rows", "csv",
    "value-col", "delta-col", "label", "format", "trend", "trend-y"];

  static styles = css`
    :host { display: inline-block; font-family: var(--wb-font); color: var(--wb-fg); }
    .shell { border: 1px solid var(--wb-border); border-radius: var(--wb-radius);
      background: var(--wb-surface); box-shadow: var(--wb-shadow-sm);
      padding: var(--wb-space-3) var(--wb-space-4); min-width: 160px; }
    :host([variant="bare"]) .shell { border: none; box-shadow: none; background: transparent; padding: 0; }
    .label { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm);
      letter-spacing: 0.04em; text-transform: uppercase; color: var(--wb-fg-muted); }
    .row { display: flex; align-items: baseline; gap: var(--wb-space-2); margin-top: var(--wb-space-1); }
    .value { font-family: var(--wb-font-display, var(--wb-font)); font-weight: 600;
      letter-spacing: -0.02em; font-size: 30px; line-height: 1.05; font-variant-numeric: tabular-nums; }
    :host([size="sm"]) .value { font-size: 22px; }
    :host([size="lg"]) .value { font-size: 42px; }
    .delta { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); font-weight: 600;
      padding: 1px 6px; border-radius: var(--wb-radius-pill); }
    .delta.up { color: var(--wb-ok); background: var(--wb-brand-soft); }
    .delta.down { color: var(--wb-err); background: rgba(201,47,47,0.12); }
    .spark { margin-top: var(--wb-space-2); }
    .err { color: var(--wb-err); font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); }
  `;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._value = null; this._delta = null; this._tier = "memory"; this._error = null;
      this._captureSource();
    }
    super.connectedCallback();
    this._load();
  }

  _captureSource() {
    this._srcName = this.attr("src-name");
    if (!this._srcName) {
      const rowsAttr = this.attr("rows"), csvAttr = this.attr("csv");
      if (rowsAttr || csvAttr) {
        if (!this._autoName) this._autoName = `work_metric_${++_autoId}`;
        this._srcName = this._autoName;
        this._pendingSource = rowsAttr ? { json: rowsAttr } : { csv: csvAttr };
      }
    }
  }

  attributeChangedCallback(name, old, val) {
    super.attributeChangedCallback(name, old, val);
    if (!this._init) return;
    if (name === "query" || name === "src-name" || name === "rows" || name === "csv" ||
        name === "value-col" || name === "delta-col") {
      this._pendingSource = null; this._captureSource(); this._load();
    } else { this.requestUpdate(); }
  }

  async _load() {
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._error = null;
      try {
        if (this._pendingSource) await this._engine.register(this._srcName, this._pendingSource);
        else if (this.hasAttribute("src-name")) await this._engine.whenRegistered(this._srcName);
        const sql = this.attr("query") || (this._srcName ? `SELECT * FROM ${ident(this._srcName)} LIMIT 1` : null);
        if (!sql) throw new Error("work-metric needs a query or a source");
        const res = await this._engine.query(sql);
        this._tier = res.engine || this._engine.provider();
        const vCol = this.attr("value-col");
        let vj = vCol ? res.columns.indexOf(vCol) : 0;
        if (vj < 0) vj = 0;
        this._value = res.rows.length ? Number(res.rows[0][vj]) : null;
        const dCol = this.attr("delta-col");
        const dj = dCol ? res.columns.indexOf(dCol) : -1;
        this._delta = dj >= 0 && res.rows.length ? Number(res.rows[0][dj]) : null;
      } catch (e) {
        this._error = String((e && e.message) || e);
      }
      this.requestUpdate();
      this._emit("work-metric-ready", { value: this._value, delta: this._delta, engine: this._tier });
    } while (this._loadAgain);
    this._loading = false;
  }

  render() {
    return html`${unsafeHTML(this._html())}`;
  }

  _html() {
    const label = this.attr("label");
    const fmt = this.attr("format");
    if (this._error) return `<div class="shell">${label ? `<div class="label">${esc(label)}</div>` : ""}<div class="err">${esc(this._error)}</div></div>`;
    const valTxt = this._value == null || Number.isNaN(this._value) ? "—" : fmtVal(this._value, fmt);
    let delta = "";
    if (this._delta != null && !Number.isNaN(this._delta)) {
      const pct = (this._delta * (Math.abs(this._delta) <= 1 ? 100 : 1));
      const up = pct >= 0;
      delta = `<span class="delta ${up ? "up" : "down"}">${up ? "▲" : "▼"} ${Math.abs(pct).toFixed(1)}%</span>`;
    }
    const trend = this.attr("trend");
    const spark = trend
      ? `<div class="spark"><work-spark query="${esc(trend)}" ${this.attr("trend-y") ? `y="${esc(this.attr("trend-y"))}"` : ""} type="area" width="140" height="28"></work-spark></div>`
      : "";
    return `<div class="shell">
      ${label ? `<div class="label">${esc(label)}</div>` : ""}
      <div class="row"><span class="value">${esc(valTxt)}</span>${delta}</div>
      ${spark}
    </div>`;
  }

  _emit(name, detail) { this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true })); }
}

function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function esc(s) { return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
function fmtVal(v, format) {
  const n = Number(v);
  if (format === "usd") return "$" + abbrev(n);
  if (format === "pct") return (n * (Math.abs(n) <= 1 ? 100 : 1)).toFixed(1) + "%";
  if (format === "num") return abbrev(n);
  return Number.isInteger(n) ? n.toLocaleString() : abbrev(n);
}
function abbrev(n) {
  const a = Math.abs(n);
  if (a >= 1e9) return (n / 1e9).toFixed(1).replace(/\.0$/, "") + "B";
  if (a >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
  if (a >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, "") + "k";
  return Number.isInteger(n) ? n.toLocaleString() : n.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

define("work-metric", WbMetric);
