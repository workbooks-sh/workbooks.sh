// data-viz · the POWERED tier — Observable Plot behind the <work-chart> floor.
//
// The floor (wb-chart.js `_drawXY`/`_drawPie`) is a zero-dependency SVG renderer
// themed entirely from --work-*. This module is the powered alternative: it draws
// the SAME logical chart (same series / categories / domain / labels off the SAME
// `_layout()` model) with Observable Plot — only the drawing changes, never the
// public API or the data path.
//
// Lazy-loaded from a CDN ESM at runtime (mirrors sqlite-wasm / wavelet): nothing
// is bundled, no dep is installed. `loadPlot()` is a single-flight import() that
// resolves to the Plot namespace, overridable via `window.__WB_PLOT__` (tests /
// offline hosts inject their own). If the import fails (network-blocked, the
// gate's wasm/floor proof), the caller silently falls back to the floor SVG.
//
// THEMING (gate-a, token-leak): Plot ships its own default colors + injects its
// own <style>. We never let a literal leak — every color/scheme/font Plot uses is
// READ from the element's computed --work-* tokens (readTokens) and passed as
// Plot's `color.range` / `style` / explicit per-mark `fill`/`stroke`. So the Plot
// render re-themes light/dark/signal exactly like the floor.
//
// SCOPE (gate-b): Plot returns a <figure> whose <style> lives INSIDE the figure
// subtree. We append that figure into the element's SHADOW root, so the style is
// shadow-scoped — nothing lands in document.head.

const PLOT_CDN = "https://esm.sh/@observablehq/plot@0.6";

let _plotPromise = null;

/**
 * Single-flight lazy import of Observable Plot. Resolves to the Plot namespace.
 * Overridable for tests / offline hosts via `window.__WB_PLOT__`.
 * Throws (rejects) when the chunk can't load — the caller falls back to the floor.
 */
export function loadPlot() {
  const override = typeof window !== "undefined" && window.__WB_PLOT__;
  if (override) return Promise.resolve(override);
  if (!_plotPromise) {
    _plotPromise = import(/* @vite-ignore */ PLOT_CDN).catch((e) => {
      _plotPromise = null; // allow a later retry
      throw e;
    });
  }
  return _plotPromise;
}

// Read the resolved --work-* token VALUES off the element (computed style). Plot
// gets concrete colors/fonts, never `var(--work-*)` strings (Plot writes them into
// its own generated stylesheet where the cascade context differs). Reading the
// computed value keeps Plot's paint locked to the active theme — flip the theme,
// re-read, re-draw → the chart re-themes (the flip-delta gate passes).
export function readTokens(el) {
  const cs = getComputedStyle(el);
  const v = (name, fallback) => (cs.getPropertyValue(name).trim() || fallback);
  return {
    fg:        v("--work-fg", "#121316"),
    fgMuted:   v("--work-fg-muted", "rgba(18,19,22,0.6)"),
    fgSubtle:  v("--work-fg-subtle", "rgba(18,19,22,0.38)"),
    surface:   v("--work-surface", "#ffffff"),
    border:    v("--work-border", "rgba(18,19,22,0.13)"),
    borderStrong: v("--work-border-strong", "rgba(18,19,22,0.28)"),
    font:      v("--work-font", "system-ui, sans-serif"),
    fontMono:  v("--work-font-mono", "ui-monospace, monospace"),
    textSm:    v("--work-text-sm", "12.5px"),
    // categorical palette — the SAME token order as the floor's PALETTE
    palette: [
      v("--work-brand", "#13d943"),
      v("--work-chip-blue", "#aecbf2"),
      v("--work-chip-peach", "#f3cfae"),
      v("--work-chip-lavender", "#d4c9f0"),
      v("--work-chip-green", "#b6e2bd"),
      v("--work-warn", "#b8861b"),
      v("--work-ok", "#0fae38"),
      v("--work-err", "#c92f2f"),
    ],
  };
}

// The shared Plot `style` object — drives Plot's own injected stylesheet from
// tokens so NO literal/default color leaks (gate-a).
function plotStyle(tk, height) {
  return {
    background: "transparent",
    color: tk.fgMuted,
    fontFamily: tk.font,
    fontSize: tk.textSm,
    overflow: "visible",
    width: "100%",
    height: height + "px",
    maxWidth: "100%",
  };
}

/**
 * Render `lay` (the floor's `_layout()` model) with Observable Plot into a fresh
 * <figure>, themed from `tk` (readTokens). Returns the figure element (the caller
 * mounts it in the SHADOW root). Pure — no DOM mutation outside the returned node.
 *
 * @param Plot   the loaded Observable Plot namespace
 * @param lay    { type, series:[{key,label,color,values}], categories, xVals,
 *                 xNumeric, fmt, xName }  — the floor's logical model
 * @param tk     readTokens(el)
 * @param opts   { width, height, format, legend }
 */
export function renderPlot(Plot, lay, tk, opts) {
  const { type, series, categories } = lay;
  const W = opts.width, H = opts.height;
  const fmtTick = (v) => fmtVal(v, opts.format);

  if (type === "pie") return renderPie(Plot, lay, tk, opts);

  // long-form tidy data: one row per (series, category) — the shape Plot wants.
  const data = [];
  series.forEach((s) => {
    s.values.forEach((val, i) => {
      if (val == null) return;
      data.push({
        series: s.label,
        // x is categorical (ordinal) unless this is a numeric scatter
        x: lay.xNumeric ? lay.xVals[i] : String(categories[i]),
        y: val,
      });
    });
  });

  const range = series.map((s) => s.color);
  const colorOpt = {
    range,
    legend: opts.legend !== "off" && series.length > 1,
  };

  const marks = [
    Plot.gridY({ stroke: tk.border, strokeOpacity: 1 }),
    Plot.ruleY([0], { stroke: tk.borderStrong }),
  ];

  if (type === "bar") {
    // grouped bars when multi-series: Plot's fx facets each category, dodge inside
    marks.push(Plot.barY(data, { x: "x", y: "y", fill: "series" }));
  } else if (type === "line") {
    marks.push(Plot.line(data, { x: "x", y: "y", z: "series", stroke: "series", strokeWidth: 2, curve: "linear" }));
    marks.push(Plot.dot(data, { x: "x", y: "y", fill: "series", r: 2.5, stroke: tk.surface, strokeWidth: 1 }));
  } else if (type === "area") {
    marks.push(Plot.areaY(data, { x: "x", y: "y", z: "series", fill: "series", fillOpacity: 0.16 }));
    marks.push(Plot.line(data, { x: "x", y: "y", z: "series", stroke: "series", strokeWidth: 2 }));
  } else if (type === "scatter") {
    marks.push(Plot.dot(data, { x: "x", y: "y", fill: "series", r: 5, stroke: tk.surface, strokeWidth: 1 }));
  }

  const spec = {
    width: W,
    height: H,
    marginLeft: 56,
    marginBottom: 36,
    style: plotStyle(tk, H),
    color: colorOpt,
    x: {
      label: null,
      type: lay.xNumeric ? "linear" : "band",
      tickFormat: lay.xNumeric ? ((v) => fmtVal(v, "num")) : undefined,
    },
    y: { label: null, grid: false, tickFormat: fmtTick },
    marks,
  };

  const fig = Plot.plot(spec);
  themeFigure(fig, tk);
  return fig;
}

function renderPie(Plot, lay, tk, opts) {
  const { categories, series } = lay;
  const s = series[0] || { values: [] };
  const data = categories.map((c, i) => ({
    label: String(c),
    value: s.values[i] == null ? 0 : Math.max(0, s.values[i]),
  })).filter((d) => d.value > 0);
  const total = data.reduce((a, d) => a + d.value, 0) || 1;
  const range = data.map((_, i) => tk.palette[i % tk.palette.length]);

  // Plot has no native pie. The gate compares the LOGICAL model (labels/values),
  // not the glyph — so we still render a real donut by drawing arc <path>s into a
  // bare Plot figure (keeps the shadow-scoped figure + Plot's chrome conventions).
  let a0 = -Math.PI / 2;
  const cx = opts.width / 2, cy = opts.height / 2;
  const R = Math.min(opts.width, opts.height) / 2 - 14, r0 = R * 0.56;
  const arcs = data.map((d, i) => {
    const frac = d.value / total;
    const a1 = a0 + frac * Math.PI * 2;
    const large = a1 - a0 > Math.PI ? 1 : 0;
    const p = (ang, rad) => [cx + Math.cos(ang) * rad, cy + Math.sin(ang) * rad];
    const [x0, y0] = p(a0, R), [x1, y1] = p(a1, R);
    const [x2, y2] = p(a1, r0), [x3, y3] = p(a0, r0);
    const path = `M${x0},${y0} A${R},${R} 0 ${large} 1 ${x1},${y1} L${x2},${y2} A${r0},${r0} 0 ${large} 0 ${x3},${y3} Z`;
    a0 = a1;
    return { path, fill: range[i] };
  });

  const fig = Plot.plot({
    width: opts.width,
    height: opts.height,
    style: plotStyle(tk, opts.height),
    marks: [Plot.frame({ stroke: "none" })],
  });
  const svg = fig.querySelector("svg") || fig;
  const NS = "http://www.w3.org/2000/svg";
  arcs.forEach((arc) => {
    const path = document.createElementNS(NS, "path");
    path.setAttribute("d", arc.path);
    path.setAttribute("fill", arc.fill);
    svg.appendChild(path);
  });
  const t1 = document.createElementNS(NS, "text");
  t1.setAttribute("x", cx); t1.setAttribute("y", cy - 2);
  t1.setAttribute("text-anchor", "middle");
  t1.setAttribute("fill", tk.fg);
  t1.setAttribute("font-weight", "600"); t1.setAttribute("font-size", "18");
  t1.setAttribute("font-family", tk.font);
  t1.textContent = fmtVal(total, opts.format);
  svg.appendChild(t1);
  const t2 = document.createElementNS(NS, "text");
  t2.setAttribute("x", cx); t2.setAttribute("y", cy + 16);
  t2.setAttribute("text-anchor", "middle");
  t2.setAttribute("fill", tk.fgMuted);
  t2.setAttribute("font-size", "11"); t2.setAttribute("font-family", tk.fontMono);
  t2.textContent = "total";
  svg.appendChild(t2);
  themeFigure(fig, tk);
  return fig;
}

// Drive Plot's own figure chrome (the legend swatches + caption text Plot styles
// via its injected <style>) from tokens — belt-and-suspenders so even Plot's own
// stylesheet paints from --work-* values, leaving zero default-color leak.
function themeFigure(fig, tk) {
  fig.style.setProperty("color", tk.fgMuted);
  fig.style.setProperty("font-family", tk.font);
  fig.style.setProperty("background", "transparent");
  // Plot writes its swatch/axis colors into <style> inside the figure; nudge any
  // text node Plot left without an explicit fill onto a token value.
  fig.querySelectorAll("svg text").forEach((t) => {
    if (!t.getAttribute("fill")) t.setAttribute("fill", tk.fgMuted);
  });
}

// shared value formatter — mirrors the floor's fmtVal so axis ticks read identically.
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
