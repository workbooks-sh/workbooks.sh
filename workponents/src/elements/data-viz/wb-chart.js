// <chart-view> — THE data-viz reinvention: a chart IS a view over a query, not a
// client-side data-wrangling widget. Aggregation / binning / grouping run IN the
// shared engine (DuckDB on the runtime tier · browser duckdb-wasm · the in-JS
// subset offline) — the element issues SQL and renders the result. Reach compute
// ONLY through the src/data layer (getEngine), exactly like the sibling
// <grid-table>. Composition-as-source: the chart carries its data + query as source.
//
// TWO render tiers behind ONE public API (attrs / events / data path identical):
//   • FLOOR — zero-dependency SVG, themed entirely from --work-* (axes, gridlines,
//     marks, legend, tooltip). The guaranteed render; never blocks on a network.
//   • POWERED — Observable Plot (./plot-tier.js), lazy-loaded from a CDN ESM at
//     runtime (overridable via window.__WB_PLOT__). Draws the SAME logical chart
//     (same _layout() model) with Plot, themed from the SAME --work-* tokens.
//   The tier resolves per-draw: `engine="plot"|"floor"` attr or
//   window.__WB_CHART_ENGINE__ force it; default "auto" prefers Plot and falls
//   back to the floor instantly if the lazy import fails (offline / blocked).
//
// Renders zero-dependency SVG themed entirely from --work-* (axes, gridlines, marks,
// legend, tooltip). Responsive (re-renders on resize). The element does NO data
// wrangling: it maps a WbQueryResult { columns, rows[i][j], types } to marks by
// the x / y / series column attributes, and nothing more.
//
// Re-based onto Lit: render() returns the Lit shell (wrapping the string-built
// chrome via unsafeHTML); the SVG itself is drawn imperatively in _draw(), invoked
// from Lit's updated() hook and on resize. The _load single-flight + stable inline
// auto-name + whenRegistered/register plumbing is unchanged.
//
// Usage (register elsewhere, aggregate IN the engine):
//   <chart-view type="bar" src-name="orders" x="region" y="revenue"
//     query="SELECT region, sum(revenue) AS revenue FROM orders GROUP BY region"></chart-view>
//
// Usage (named source, default SELECT — x/y pick columns off the result):
//   <chart-view type="line" src-name="daily" x="day" y="visits"></chart-view>
//
// Usage (bind to a <data-query> by name — the canonical data binding):
//   <data-query name="daily" sql="SELECT day, visits FROM events"></data-query>
//   <chart-view type="line" from="daily" x="day" y="visits"></chart-view>
//
// Usage (inline data, no engine round-trip beyond registration):
//   <chart-view type="scatter" x="x" y="y" rows='[{"x":1,"y":3},{"x":2,"y":5}]'></chart-view>
//
// Attributes:
//   type        bar | line | area | scatter | pie   (the chart variant)
//   from        name of a <data-query> dataset to read (the canonical binding)
//   src-name    name of a source registered via getEngine().register(...)
//   query       full SQL to run (the aggregate/GROUP BY lives HERE, in the engine)
//   rows        inline JSON array of row objects (registers an auto-named source)
//   csv         inline CSV text (header row) → auto-named source
//   x           column for the category / x axis (default: first column)
//   y           column(s) for the value axis — comma-separated for multi-series
//   series      a column whose distinct values become series (long → wide, in JS
//               layout only; the values themselves come straight from the result)
//   label       pie: slice-label column (default = x); value = y
//   size        sm | md | lg     (chart height preset)
//   variant     card | bare      (visual shell)
//   engine      auto | plot | floor   (render tier — see below)
//   legend      auto | off       (default auto: shown when >1 series)
//   format      usd | num | pct | none   (value formatting in axis + tooltip)
//   title       optional heading rendered in the shell
//
// Events:
//   work-chart-ready   { detail: { type, columns, types, engine, series, rowCount } }
//   work-chart-query   { detail: { sql, rowCount, engine } }      on every (re)query
//   work-point-select  { detail: { series, x, y, row, index } }   on hover/click a mark
import { WbElement, html, css, define } from "../../core/element.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";
import { defineVariants, variantAttrs, resolveVariant } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import { loadPlot, readTokens, renderPlot } from "./plot-tier.js";

const VARIANTS = defineVariants({
  type: { options: ["bar", "line", "area", "scatter", "pie"], default: "bar" },
  size: { options: ["sm", "md", "lg"], default: "md" },
  variant: { options: ["card", "bare"], default: "card" },
});

const HEIGHTS = { sm: 180, md: 300, lg: 440 };
// Categorical palette — pastel chips first, then brand/state tokens. Pure tokens.
const PALETTE = [
  "var(--work-brand)", "var(--work-chip-blue)", "var(--work-chip-peach)",
  "var(--work-chip-lavender)", "var(--work-chip-green)", "var(--work-warn)",
  "var(--work-ok)", "var(--work-err)",
];

let _autoId = 0;

export class WbChart extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "src-name", "from", "query", "rows", "csv",
    "x", "y", "series", "label", "legend", "format", "title",
    "engine",   // tier override: auto (default, prefer Plot) | plot | floor
  ];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell { border: 1px solid var(--work-border); border-radius: var(--work-radius);
      background: var(--work-surface); overflow: hidden; box-shadow: var(--work-shadow-sm); }
    :host([variant="bare"]) .shell { border: none; box-shadow: none; background: transparent; }

    .head { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-3) var(--work-space-4) 0; }
    .title { font-family: var(--work-font-display, var(--work-font)); font-weight: 600;
      font-size: var(--work-text-lg); letter-spacing: -0.01em; }
    .grow { flex: 1; }
    .engine { display: inline-flex; align-items: center; gap: var(--work-space-1);
      font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-subtle); }
    .dot { width: 7px; height: 7px; border-radius: var(--work-radius-pill); background: var(--work-brand);
      box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .engine[data-tier="memory"] .dot { background: var(--work-warn); box-shadow: 0 0 0 3px var(--work-warn-soft); }
    .engine[data-tier="error"] .dot { background: var(--work-err); box-shadow: none; }

    .plot { padding: var(--work-space-3) var(--work-space-4) var(--work-space-4); position: relative; }
    .powered:empty { display: none; }
    /* when the powered tier (Observable Plot) has rendered into .powered, the floor
       SVG is declaratively hidden — no imperative show/hide race against Lit's
       shell re-render or the ResizeObserver. */
    .plot:has(.powered > *) svg { display: none; }
    .powered > * { width: 100%; }
    svg { display: block; width: 100%; height: auto; overflow: visible; }
    text { font-family: var(--work-font); fill: var(--work-fg-muted); }
    .axis-label { fill: var(--work-fg-muted); font-size: var(--work-text-xs); }
    .axis-line { stroke: var(--work-border-strong); stroke-width: 1; }
    .grid { stroke: var(--work-border); stroke-width: 1; }
    .mark { transition: opacity var(--work-dur) var(--work-ease); cursor: pointer; }
    .plot[data-hover] .mark:not([data-active]) { opacity: 0.32; }
    .bar-rect { rx: 3; }
    .line-path { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
    .area-fill { opacity: 0.16; }
    .dot-mark { stroke: var(--work-surface); stroke-width: 1.5; }

    .legend { display: flex; flex-wrap: wrap; gap: var(--work-space-3);
      padding: 0 var(--work-space-4) var(--work-space-3); font-size: var(--work-text-sm); color: var(--work-fg-muted); }
    .legend .key { display: inline-flex; align-items: center; gap: var(--work-space-1); cursor: default; }
    .legend .swatch { width: 11px; height: 11px; border-radius: var(--work-radius-xs); }

    .tip { position: absolute; pointer-events: none; z-index: 3; opacity: 0;
      transform: translate(-50%, calc(-100% - 10px));
      background: var(--work-fg); color: var(--work-surface);
      font-family: var(--work-font-mono); font-size: var(--work-text-sm);
      padding: var(--work-space-1) var(--work-space-2); border-radius: var(--work-radius-sm);
      white-space: nowrap; box-shadow: var(--work-shadow); transition: opacity var(--work-dur) var(--work-ease); }
    .tip[data-show] { opacity: 1; }
    .tip .tk { color: var(--work-surface-soft); }

    .empty { padding: var(--work-space-5); text-align: center; color: var(--work-fg-muted); font-size: var(--work-text-sm); }
    .foot { padding: 0 var(--work-space-4) var(--work-space-3); font-size: var(--work-text-sm); color: var(--work-fg-subtle);
      font-family: var(--work-font-mono); }
    .foot .err { color: var(--work-err); }
  `;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._result = null;
      this._tier = "memory";
      this._error = null;
      this._busy = true;
      this._series = [];            // [{ key, label, color }]
      this._captureSource();
      this._ro = new ResizeObserver(() => this._draw());
    }
    super.connectedCallback();
    this._ro.observe(this);
    this._load();
  }

  disconnectedCallback() {
    if (this._ro) this._ro.disconnect();
    super.disconnectedCallback();
  }

  // A named source: from="<data-query name>" is the canonical binding; src-name is
  // the equivalent register()-side name. Either names a source the engine resolves.
  _namedSource() { return this.attr("from") || this.attr("src-name"); }

  _captureSource() {
    this._srcName = this._namedSource();
    if (!this._srcName) {
      const rowsAttr = this.attr("rows");
      const csvAttr = this.attr("csv");
      if (!this._autoName) this._autoName = `work_chart_${++_autoId}`;
      this._srcName = this._autoName;
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
    super.attributeChangedCallback(name, old, val);
    if (!this._init) return;
    if (name === "rows" || name === "csv" || name === "src-name" || name === "from" || name === "query") {
      this._pendingSource = null;
      this._captureSource();
      this._load();
    } else {
      // re-layout / re-render from the cached result; no re-query needed
      this.requestUpdate();
    }
  }

  async _load() {
    // Single-flight: overlapping loads would let one load's register()
    // (DROP+CREATE) yank the table out from under another's in-flight query.
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._busy = true; this._error = null; this.requestUpdate();
      try {
        if (this._pendingSource) await this._engine.register(this._srcName, this._pendingSource);
        else if (this._namedSource()) await this._engine.whenRegistered(this._srcName);
        await this._run();
      } catch (e) {
        this._error = String((e && e.message) || e);
        this._tier = "error";
      }
      this._busy = false;
      this.requestUpdate();
      this._emit("work-chart-ready", {
        type: this.variant("type"),
        columns: this._result?.columns || [],
        types: this._result?.types || [],
        engine: this._tier,
        series: this._series.map((s) => s.key),
        rowCount: this._result?.rowCount || 0,
      });
    } while (this._loadAgain);
    this._loading = false;
  }

  async _run() {
    // The aggregate/GROUP BY lives in the author's `query` (engine-computed). With
    // no query, default to SELECT * over the named source — the engine still
    // answers; the element never wrangles.
    const sql = this.attr("query") || `SELECT * FROM ${ident(this._srcName)}`;
    this._result = await this._engine.query(sql);
    this._tier = this._result.engine || this._engine.provider();
    this._emit("work-chart-query", { sql, rowCount: this._result.rowCount, engine: this._tier });
  }

  variant(name) { return resolveVariant(this, VARIANTS, name); }

  // The canonical LOGICAL model of the chart — series, data-point count, domain,
  // category labels — independent of which tier drew it. The parity gate uses this
  // off the FLOOR render as the oracle (the floor maps the engine result directly,
  // so it IS the ground truth for "what the data says"). Pure read of _layout().
  _logicalModel() {
    const lay = this._layout();
    if (!lay) return { seriesCount: 0, pointCount: 0, yMin: null, yMax: null, categories: [], seriesLabels: [] };
    let yMin = Infinity, yMax = -Infinity, pointCount = 0;
    for (const s of lay.series) for (const v of s.values) {
      if (v == null) continue;
      pointCount++;
      if (v < yMin) yMin = v;
      if (v > yMax) yMax = v;
    }
    return {
      type: lay.type,
      seriesCount: lay.series.length,
      pointCount,
      yMin: isFinite(yMin) ? yMin : null,
      yMax: isFinite(yMax) ? yMax : null,
      categories: lay.categories.map((c) => String(c)),
      seriesLabels: lay.series.map((s) => String(s.label)),
    };
  }

  // ── render (shell only; the SVG is drawn imperatively in _draw) ───────────────
  render() {
    const title = this.attr("title");
    const tierText = this._busy ? "querying…" :
      this._error ? "engine error" :
      this._tier === "runtime" ? "runtime DuckDB" :
      this._tier === "duckdb-wasm" ? "DuckDB-wasm" : "in-JS (offline)";
    const head = `
      <div class="head">
        ${title ? `<span class="title">${esc(title)}</span>` : ""}
        <span class="grow"></span>
        <span class="engine" data-tier="${this._error ? "error" : this._tier}"><span class="dot"></span>${esc(tierText)}</span>
      </div>`;
    const shell = `<div class="shell">
      ${head}
      <div class="plot"><div class="tip"></div><div class="powered" part="powered"></div><svg part="svg"></svg></div>
      <div class="legend"></div>
      <div class="foot">${this._error ? `<span class="err">${esc(this._error)}</span>` : ""}</div>
    </div>`;
    return html`${unsafeHTML(shell)}`;
  }

  // Lit lifecycle: the shell just (re)rendered — draw the SVG against the cached
  // result (base used to do this in an update() override; Lit's hook is updated()).
  updated() {
    if (this._result && !this._busy) this._draw();
    else this._draw(); // clears / shows empty as needed
  }

  // ── layout: map the WbQueryResult { columns, rows[][], types } to marks ───────
  _layout() {
    const r = this._result;
    if (!r || !r.columns.length || !r.rows.length) return null;
    const cols = r.columns;
    const idx = (name) => cols.indexOf(name);

    const type = this.variant("type");
    const fmt = this.attr("format");
    const xName = this.attr("x") || cols[0];
    const xj = idx(xName) >= 0 ? idx(xName) : 0;

    // y columns: explicit list, else the series-pivot column, else "all numeric
    // columns that are not x". Series are layout only — values come from rows[][].
    const seriesCol = this.attr("series");
    let yNames = (this.attr("y") || "").split(",").map((s) => s.trim()).filter(Boolean);

    let categories, series;
    const colorFor = (i) => PALETTE[i % PALETTE.length];

    if (seriesCol && yNames.length === 1) {
      // long → wide: distinct values of seriesCol become series, yNames[0] is the value
      const sj = idx(seriesCol), yj = idx(yNames[0]);
      const catSet = [], catPos = new Map();
      const keys = [], keyPos = new Map();
      for (const row of r.rows) {
        const c = row[xj];
        if (!catPos.has(c)) { catPos.set(c, catSet.length); catSet.push(c); }
        const k = row[sj];
        if (!keyPos.has(k)) { keyPos.set(k, keys.length); keys.push(k); }
      }
      categories = catSet;
      series = keys.map((k, i) => ({
        key: String(k), label: String(k), color: colorFor(i),
        values: new Array(catSet.length).fill(null),
      }));
      for (const row of r.rows) {
        const ci = catPos.get(row[xj]);
        const si = keyPos.get(row[sj]);
        series[si].values[ci] = toNum(row[yj]);
      }
    } else {
      if (!yNames.length) {
        // every numeric column except x
        yNames = cols.filter((c, j) => j !== xj && (r.types[j] === "number" || r.types[j] === "integer"));
        if (!yNames.length) yNames = cols.filter((_, j) => j !== xj).slice(0, 1);
      }
      categories = r.rows.map((row) => row[xj]);
      series = yNames.map((name, i) => ({
        key: name, label: prettify(name), color: colorFor(i),
        values: r.rows.map((row) => toNum(row[idx(name)])),
      }));
    }

    // x values for scatter are numeric; otherwise categorical/ordinal index
    const xNumeric = type === "scatter" && (r.types[xj] === "number" || r.types[xj] === "integer");
    const xVals = categories.map((c) => (xNumeric ? toNum(c) : c));

    this._series = series;
    return { type, fmt, xName, categories, xVals, xNumeric, series, rows: r.rows, xj };
  }

  // Which tier should draw? floor (zero-dep SVG) vs plot (Observable Plot).
  //   - attribute engine="floor" | "plot" forces it (the gate drives this)
  //   - window.__WB_CHART_ENGINE__ = "floor" | "plot" is the host opt-out
  //   - default "auto": prefer Plot when it loads, fall back to the floor.
  // Returns "floor" | "plot". A non-floor verdict still falls back to the floor
  // synchronously if Plot has not resolved yet (the floor never blocks on a CDN).
  _tierChoice() {
    const attr = this.attr("engine");
    if (attr === "floor" || attr === "plot") return attr;
    const host = typeof window !== "undefined" && window.__WB_CHART_ENGINE__;
    if (host === "floor" || host === "plot") return host;
    return "auto";
  }

  _draw() {
    const svg = this.shadowRoot && this.shadowRoot.querySelector("svg");
    const powered = this.shadowRoot && this.shadowRoot.querySelector(".powered");
    if (!svg) return;
    const lay = this._layout();
    const legendEl = this.shadowRoot.querySelector(".legend");
    if (!lay) {
      svg.innerHTML = "";
      svg.removeAttribute("viewBox");
      if (powered) powered.innerHTML = "";
      if (legendEl) legendEl.innerHTML = "";
      if (!this._busy && !this._error) {
        const plot = this.shadowRoot.querySelector(".plot");
        if (plot && !plot.querySelector(".empty")) {
          const e = document.createElement("div");
          e.className = "empty"; e.textContent = "No data.";
          plot.appendChild(e);
        }
      }
      return;
    }
    const plot = this.shadowRoot.querySelector(".plot");
    const oldEmpty = plot && plot.querySelector(".empty");
    if (oldEmpty) oldEmpty.remove();

    const choice = this._tierChoice();
    if (choice === "floor") return this._drawFloor(svg, powered, lay, legendEl);

    // powered path. If Plot has already resolved (cached on the instance), render
    // it SYNCHRONOUSLY this frame — no floor flash, no svg un-hide race on resize.
    // Otherwise draw the floor instantly (never a blank chart) and upgrade to Plot
    // once the lazy import lands.
    if (this._Plot && powered) {
      const ok = this._renderPoweredSync(svg, powered, lay, legendEl, this._Plot, choice === "plot");
      if (ok) return;
    }
    this._drawFloor(svg, powered, lay, legendEl);
    this._drawPowered(svg, powered, lay, legendEl, choice === "plot");
  }

  // Render the Plot figure into the powered host with an already-loaded Plot ns.
  // Returns true on success (svg hidden, figure shown); false to fall to floor.
  _renderPoweredSync(svg, powered, lay, legendEl, Plot, forced) {
    if (!this._result) return false;
    const tk = readTokens(this);
    const W = Math.max(320, this.getBoundingClientRect().width || 640);
    const H = HEIGHTS[this.variant("size")] || HEIGHTS.md;
    let fig;
    try {
      fig = renderPlot(Plot, lay, tk, {
        width: W, height: H, format: lay.fmt, legend: this.attr("legend", "auto"),
      });
    } catch (e) {
      if (forced) console.warn("chart-view: Plot render failed, keeping floor", e);
      return false;
    }
    powered.innerHTML = "";
    powered.appendChild(fig);
    // the floor SVG is hidden declaratively by CSS (.plot:has(.powered > *) svg);
    // clear its marks so it carries no stale render behind the figure.
    svg.innerHTML = "";
    svg.removeAttribute("viewBox");
    if (legendEl) legendEl.innerHTML = "";
    this._engineTier = "plot";
    this._wirePlotSelect(fig, lay);
    return true;
  }

  // The zero-dependency SVG floor (the original renderer). Hides the powered host.
  _drawFloor(svg, powered, lay, legendEl) {
    if (powered) powered.innerHTML = "";   // empty .powered → CSS shows the floor svg
    const H = HEIGHTS[this.variant("size")] || HEIGHTS.md;
    // viewBox-driven so the SVG scales fluidly; width:100% in CSS.
    const vbW = Math.max(320, this.getBoundingClientRect().width || 640);
    const vbH = H;
    if (lay.type === "pie") this._drawPie(svg, lay, vbW, vbH);
    else this._drawXY(svg, lay, vbW, vbH);
    this._drawLegend(legendEl, lay);
    this._wireHover(svg, lay);
    this._engineTier = "floor";
  }

  // The POWERED tier — Observable Plot, lazy-loaded. On success it replaces the
  // floor SVG with a Plot <figure> rendered from the SAME `lay` model, themed from
  // the live --work-* tokens. On failure (network-blocked / load error) it leaves
  // the floor in place (forced="plot" still degrades gracefully — the floor IS the
  // guaranteed render; the gate proves this).
  async _drawPowered(svg, powered, lay, legendEl, forced) {
    if (!powered) return;
    const token = (this._drawToken = (this._drawToken || 0) + 1);
    let Plot;
    try { Plot = await loadPlot(); }
    catch { return; /* floor already drawn — graceful degrade */ }
    if (token !== this._drawToken) return;      // a newer draw superseded this one
    this._Plot = Plot;                          // cache so later draws go sync
    const ok = this._renderPoweredSync(svg, powered, lay, legendEl, Plot, forced);
    if (ok) this._emit("work-chart-engine", { engine: "plot" });
  }

  // Forward Plot mark clicks to the SAME work-point-select contract as the floor.
  _wirePlotSelect(fig, lay) {
    const r = this._result;
    fig.querySelectorAll("[fill]").forEach((mark) => {
      mark.style.cursor = "pointer";
      mark.addEventListener("click", () => {
        // Plot bars/dots carry their datum index in document order; map back to
        // the layout. We approximate by reading the mark's __data__ when present.
        const d = mark.__data__;
        if (d == null) return;
        this._emit("work-point-select", { series: d.series, x: d.x, y: d.y, row: d, index: -1 });
      });
    });
  }

  _drawXY(svg, lay, W, H) {
    const { type, series, categories, xVals, xNumeric, fmt } = lay;
    const padL = 52, padR = 16, padT = 12, padB = 34;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;

    // y domain across all series; bars/areas baseline at 0
    let yMin = Infinity, yMax = -Infinity;
    for (const s of series) for (const v of s.values) {
      if (v == null) continue;
      if (v < yMin) yMin = v;
      if (v > yMax) yMax = v;
    }
    if (!isFinite(yMin)) { yMin = 0; yMax = 1; }
    if (type === "bar" || type === "area") yMin = Math.min(0, yMin);
    if (yMin === yMax) yMax = yMin + 1;
    const ticks = niceTicks(yMin, yMax, 5);
    yMin = ticks[0]; yMax = ticks[ticks.length - 1];
    const yScale = (v) => padT + plotH - ((v - yMin) / (yMax - yMin)) * plotH;

    // x scale
    const n = categories.length;
    let xScale, bandW;
    if (xNumeric) {
      let xmin = Infinity, xmax = -Infinity;
      for (const v of xVals) { if (v < xmin) xmin = v; if (v > xmax) xmax = v; }
      if (xmin === xmax) { xmin -= 0.5; xmax += 0.5; }
      xScale = (v) => padL + ((v - xmin) / (xmax - xmin)) * plotW;
      bandW = 0;
    } else {
      bandW = plotW / Math.max(1, n);
      xScale = (i) => padL + bandW * i + bandW / 2;   // category center
    }

    const parts = [];
    // gridlines + y axis ticks
    for (const t of ticks) {
      const y = yScale(t);
      parts.push(`<line class="grid" x1="${padL}" y1="${y.toFixed(1)}" x2="${(W - padR).toFixed(1)}" y2="${y.toFixed(1)}"/>`);
      parts.push(`<text class="axis-label" x="${padL - 8}" y="${(y + 3.5).toFixed(1)}" text-anchor="end">${esc(fmtVal(t, fmt))}</text>`);
    }
    // x baseline
    const y0 = yScale(Math.max(yMin, 0));
    parts.push(`<line class="axis-line" x1="${padL}" y1="${y0.toFixed(1)}" x2="${(W - padR).toFixed(1)}" y2="${y0.toFixed(1)}"/>`);

    // x category labels (thinned to avoid overlap)
    const step = Math.ceil(n / Math.max(1, Math.floor(plotW / 64)));
    if (!xNumeric) {
      categories.forEach((c, i) => {
        if (i % step !== 0) return;
        parts.push(`<text class="axis-label" x="${xScale(i).toFixed(1)}" y="${(H - padB + 18).toFixed(1)}" text-anchor="middle">${esc(trunc(c, 12))}</text>`);
      });
    } else {
      // numeric x ticks
      const xt = niceTicks(Math.min(...xVals), Math.max(...xVals), 5);
      for (const t of xt) parts.push(`<text class="axis-label" x="${xScale(t).toFixed(1)}" y="${(H - padB + 18).toFixed(1)}" text-anchor="middle">${esc(fmtVal(t, "num"))}</text>`);
    }

    // marks
    if (type === "bar") {
      const sCount = series.length;
      const groupPad = bandW * 0.18;
      const innerW = bandW - groupPad * 2;
      const barW = innerW / sCount;
      series.forEach((s, si) => {
        s.values.forEach((v, i) => {
          if (v == null) return;
          const x = padL + bandW * i + groupPad + barW * si;
          const yv = yScale(v);
          const h = Math.abs(y0 - yv);
          parts.push(`<rect class="mark bar-rect" data-s="${si}" data-i="${i}" x="${x.toFixed(1)}" y="${Math.min(y0, yv).toFixed(1)}" width="${Math.max(0.5, barW - 1.5).toFixed(1)}" height="${h.toFixed(1)}" fill="${s.color}"/>`);
        });
      });
    } else if (type === "line" || type === "area") {
      series.forEach((s, si) => {
        const pts = [];
        s.values.forEach((v, i) => {
          if (v == null) return;
          const x = xNumeric ? xScale(xVals[i]) : xScale(i);
          pts.push([x, yScale(v), i]);
        });
        if (!pts.length) return;
        const d = pts.map((p, k) => `${k ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
        if (type === "area") {
          const base = `${d} L${pts[pts.length - 1][0].toFixed(1)},${y0.toFixed(1)} L${pts[0][0].toFixed(1)},${y0.toFixed(1)} Z`;
          parts.push(`<path class="area-fill" d="${base}" fill="${s.color}"/>`);
        }
        parts.push(`<path class="line-path" d="${d}" stroke="${s.color}"/>`);
        // point handles for hover/select
        pts.forEach((p) => parts.push(`<circle class="mark dot-mark" data-s="${si}" data-i="${p[2]}" cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="3.5" fill="${s.color}"/>`));
      });
    } else if (type === "scatter") {
      series.forEach((s, si) => {
        s.values.forEach((v, i) => {
          if (v == null) return;
          const x = xNumeric ? xScale(xVals[i]) : xScale(i);
          parts.push(`<circle class="mark dot-mark" data-s="${si}" data-i="${i}" cx="${x.toFixed(1)}" cy="${yScale(v).toFixed(1)}" r="5" fill="${s.color}"/>`);
        });
      });
    }

    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    svg.innerHTML = parts.join("");
  }

  _drawPie(svg, lay, W, H) {
    const { series, categories, fmt } = lay;
    // pie uses the FIRST series' values; slices = categories
    const s = series[0];
    const vals = s.values.map((v) => (v == null ? 0 : Math.max(0, v)));
    const total = vals.reduce((a, b) => a + b, 0) || 1;
    const cx = W / 2, cy = H / 2, R = Math.min(W, H) / 2 - 14, r0 = R * 0.56;
    const parts = [];
    let a0 = -Math.PI / 2;
    // rebuild "series" as one-slice-per-category for legend + hover semantics
    const slices = [];
    categories.forEach((c, i) => {
      const frac = vals[i] / total;
      if (frac <= 0) { slices.push({ label: String(c), color: PALETTE[i % PALETTE.length], value: vals[i], pct: 0 }); return; }
      const a1 = a0 + frac * Math.PI * 2;
      const large = a1 - a0 > Math.PI ? 1 : 0;
      const p = (ang, rad) => `${(cx + Math.cos(ang) * rad).toFixed(1)},${(cy + Math.sin(ang) * rad).toFixed(1)}`;
      const d = `M${p(a0, R)} A${R},${R} 0 ${large} 1 ${p(a1, R)} L${p(a1, r0)} A${r0},${r0} 0 ${large} 0 ${p(a0, r0)} Z`;
      const color = PALETTE[i % PALETTE.length];
      parts.push(`<path class="mark" data-s="0" data-i="${i}" d="${d}" fill="${color}"/>`);
      slices.push({ label: String(c), color, value: vals[i], pct: frac });
      a0 = a1;
    });
    // center total
    parts.push(`<text x="${cx}" y="${cy - 2}" text-anchor="middle" style="fill:var(--work-fg);font-weight:600;font-size:18px">${esc(fmtVal(total, fmt))}</text>`);
    parts.push(`<text x="${cx}" y="${cy + 16}" text-anchor="middle" class="axis-label" style="font-family:var(--work-font-mono)">total</text>`);
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    svg.innerHTML = parts.join("");
    lay._slices = slices;   // for legend + hover
  }

  _drawLegend(el, lay) {
    if (!el) return;
    const mode = this.attr("legend", "auto");
    const keys = lay.type === "pie"
      ? (lay._slices || []).map((s) => ({ label: trunc(s.label, 18), color: s.color }))
      : lay.series.map((s) => ({ label: trunc(s.label, 18), color: s.color }));
    if (mode === "off" || keys.length <= 1) { el.innerHTML = ""; return; }
    el.innerHTML = keys.map((k) =>
      `<span class="key"><span class="swatch" style="background:${k.color}"></span>${esc(k.label)}</span>`).join("");
  }

  _wireHover(svg, lay) {
    const tip = this.shadowRoot.querySelector(".tip");
    const plot = this.shadowRoot.querySelector(".plot");
    const fmt = lay.fmt;
    const r = this._result;
    const marks = svg.querySelectorAll(".mark");
    const show = (mark, ev) => {
      const si = +mark.getAttribute("data-s");
      const i = +mark.getAttribute("data-i");
      marks.forEach((m) => m.removeAttribute("data-active"));
      mark.setAttribute("data-active", "");
      plot.setAttribute("data-hover", "");
      let label, value;
      if (lay.type === "pie") {
        const sl = lay._slices[i];
        label = sl.label; value = `${fmtVal(sl.value, fmt)} · ${(sl.pct * 100).toFixed(1)}%`;
      } else {
        const s = lay.series[si];
        label = `${esc(s.label)} · ${esc(trunc(lay.categories[i], 18))}`;
        value = fmtVal(s.values[i], fmt);
      }
      tip.innerHTML = `<span class="tk">${esc(label)}</span> ${esc(value)}`;
      const box = plot.getBoundingClientRect();
      tip.style.left = (ev.clientX - box.left) + "px";
      tip.style.top = (ev.clientY - box.top) + "px";
      tip.setAttribute("data-show", "");
    };
    const hide = () => {
      tip.removeAttribute("data-show");
      plot.removeAttribute("data-hover");
      marks.forEach((m) => m.removeAttribute("data-active"));
    };
    marks.forEach((mark) => {
      mark.addEventListener("mousemove", (ev) => show(mark, ev));
      mark.addEventListener("mouseleave", hide);
      mark.addEventListener("click", () => {
        const si = +mark.getAttribute("data-s");
        const i = +mark.getAttribute("data-i");
        const rowObj = {};
        if (r) r.columns.forEach((c, j) => (rowObj[c] = r.rows[i] ? r.rows[i][j] : null));
        const s = lay.series[si];
        this._emit("work-point-select", {
          series: lay.type === "pie" ? lay._slices[i].label : s.key,
          x: lay.categories[i],
          y: lay.type === "pie" ? lay._slices[i].value : s.values[i],
          row: rowObj, index: i,
        });
      });
    });
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

// ── helpers (token-unaware) ──────────────────────────────────────────────────
function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function toNum(v) { if (v == null || v === "") return null; const n = Number(v); return Number.isNaN(n) ? null : n; }
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
function prettify(f) { return String(f).replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }
function trunc(s, n) { s = String(s ?? ""); return s.length > n ? s.slice(0, n - 1) + "…" : s; }
function fmtVal(v, format) {
  if (v == null) return "";
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
// "Nice" axis ticks (1/2/5 × 10^k), inclusive of rounded min/max.
function niceTicks(min, max, count) {
  if (min === max) { min -= 1; max += 1; }
  const span = niceNum(max - min, false);
  const stepc = niceNum(span / Math.max(1, count - 1), true);
  const niceMin = Math.floor(min / stepc) * stepc;
  const niceMax = Math.ceil(max / stepc) * stepc;
  const out = [];
  for (let v = niceMin; v <= niceMax + stepc * 0.5; v += stepc) out.push(+v.toFixed(10));
  return out;
}
function niceNum(range, round) {
  const exp = Math.floor(Math.log10(range || 1));
  const frac = (range || 1) / Math.pow(10, exp);
  let nf;
  if (round) nf = frac < 1.5 ? 1 : frac < 3 ? 2 : frac < 7 ? 5 : 10;
  else nf = frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 5 ? 5 : 10;
  return nf * Math.pow(10, exp);
}

define("chart-view", WbChart);
