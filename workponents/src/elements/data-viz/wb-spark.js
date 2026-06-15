// <wb-spark> — an inline sparkline. A trend IS a query: the element runs SQL on
// the shared engine and draws a tiny zero-dependency SVG line/area/bar from the
// result's value column. No axes, no chrome — it sits inline in text, a table
// cell, or a <wb-metric>. Same data contract + same engine as <wb-chart>; reach
// compute ONLY through src/data.
//
// Usage:
//   <wb-spark src-name="daily" y="visits"></wb-spark>
//   <wb-spark type="area" query="SELECT day, sum(rev) AS rev FROM orders GROUP BY day ORDER BY day" y="rev"></wb-spark>
//   <wb-spark type="bar" rows='[{"v":3},{"v":7},{"v":4},{"v":9}]' y="v"></wb-spark>
//
// Attributes:
//   type       line | area | bar     (default line)
//   src-name / query / rows / csv    — same source story as <wb-chart>
//   y          value column (default: first numeric column)
//   tone       brand | ok | warn | err | neutral   (stroke color, a --wb-* token)
//   width      px hint for the inline box (default 96)
//   height     px hint (default 24)
//
// Events: wb-spark-ready { detail: { points, min, max, last, engine } }
import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs, resolveVariant } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";

const VARIANTS = defineVariants({
  type: { options: ["line", "area", "bar"], default: "line" },
  tone: { options: ["brand", "ok", "warn", "err", "neutral"], default: "brand" },
});
const TONE = { brand: "var(--wb-brand)", ok: "var(--wb-ok)", warn: "var(--wb-warn)", err: "var(--wb-err)", neutral: "var(--wb-fg-muted)" };

let _autoId = 0;

export class WbSpark extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "src-name", "query", "rows", "csv", "y", "width", "height"];

  static styles = `
    :host { display: inline-block; vertical-align: middle; line-height: 0; }
    svg { display: block; overflow: visible; }
    .line { fill: none; stroke-width: 1.75; stroke-linejoin: round; stroke-linecap: round; }
    .area { opacity: 0.18; }
    .bar { rx: 0.8; }
    .last { stroke: var(--wb-surface); stroke-width: 1; }
  `;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._values = null;
      this._tier = "memory";
      this._captureSource();
    }
    super.connectedCallback();
    this._load();
  }

  _captureSource() {
    this._srcName = this.attr("src-name");
    if (!this._srcName) {
      const rowsAttr = this.attr("rows"), csvAttr = this.attr("csv");
      this._srcName = `wb_spark_${++_autoId}`;
      if (rowsAttr) this._pendingSource = { json: rowsAttr };
      else if (csvAttr) this._pendingSource = { csv: csvAttr };
    }
  }

  attributeChangedCallback(name) {
    if (!this._connected) return;
    if (name === "rows" || name === "csv" || name === "src-name" || name === "query" || name === "y") {
      this._pendingSource = null;
      this._captureSource();
      this._load();
    } else { this.update(); }
  }

  async _load() {
    try {
      if (this._pendingSource) await this._engine.register(this._srcName, this._pendingSource);
      const sql = this.attr("query") || `SELECT * FROM ${ident(this._srcName)}`;
      const res = await this._engine.query(sql);
      this._tier = res.engine || this._engine.provider();
      const yName = this.attr("y");
      let j = yName ? res.columns.indexOf(yName) : -1;
      if (j < 0) j = res.types.findIndex((t) => t === "number" || t === "integer");
      if (j < 0) j = res.columns.length - 1;
      this._values = res.rows.map((row) => { const n = Number(row[j]); return Number.isNaN(n) ? null : n; });
    } catch (e) {
      this._values = null;
    }
    this.update();
    const vs = (this._values || []).filter((v) => v != null);
    this._emit("wb-spark-ready", {
      points: this._values?.length || 0,
      min: vs.length ? Math.min(...vs) : null,
      max: vs.length ? Math.max(...vs) : null,
      last: vs.length ? vs[vs.length - 1] : null,
      engine: this._tier,
    });
  }

  render() {
    const W = +this.attr("width", "96"), H = +this.attr("height", "24");
    const vs = this._values;
    if (!vs || !vs.length) return `<svg width="${W}" height="${H}"></svg>`;
    const pad = 2;
    const nums = vs.filter((v) => v != null);
    let min = Math.min(...nums), max = Math.max(...nums);
    if (min === max) { min -= 1; max += 1; }
    const type = resolveVariant(this, VARIANTS, "type");
    const color = TONE[resolveVariant(this, VARIANTS, "tone")] || TONE.brand;
    const x = (i) => pad + (vs.length === 1 ? (W - 2 * pad) / 2 : (i / (vs.length - 1)) * (W - 2 * pad));
    const y = (v) => pad + (1 - (v - min) / (max - min)) * (H - 2 * pad);

    if (type === "bar") {
      const bw = (W - 2 * pad) / vs.length;
      const y0 = y(Math.max(min, 0));
      const bars = vs.map((v, i) => {
        if (v == null) return "";
        const bx = pad + bw * i, yy = y(v), h = Math.abs(y0 - yy);
        return `<rect class="bar" x="${(bx + 0.5).toFixed(1)}" y="${Math.min(y0, yy).toFixed(1)}" width="${Math.max(0.5, bw - 1).toFixed(1)}" height="${h.toFixed(1)}" fill="${color}"/>`;
      }).join("");
      return `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${bars}</svg>`;
    }

    const pts = vs.map((v, i) => (v == null ? null : [x(i), y(v)])).filter(Boolean);
    const d = pts.map((p, k) => `${k ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
    const last = pts[pts.length - 1];
    let area = "";
    if (type === "area" && pts.length > 1) {
      const base = `${d} L${pts[pts.length - 1][0].toFixed(1)},${(H - pad).toFixed(1)} L${pts[0][0].toFixed(1)},${(H - pad).toFixed(1)} Z`;
      area = `<path class="area" d="${base}" fill="${color}"/>`;
    }
    return `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
      ${area}<path class="line" d="${d}" stroke="${color}"/>
      ${last ? `<circle class="last" cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="2" fill="${color}"/>` : ""}
    </svg>`;
  }

  _emit(name, detail) { this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true })); }
}

function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }

define("wb-spark", WbSpark);
