// <map-view> — THE maps reinvention: the map IS a SPATIAL VIEW OVER A QUERY, not a
// hand-fed GeoJSON blob. Points / regions come from query ROWS — lat/lon (and an
// optional value) are columns of a WbQueryResult. Spatial filtering and
// aggregation belong IN the engine (SQL: GROUP BY region, WHERE lon BETWEEN …),
// never in JS. The element is a thin, themed, pan/zoom viewport over the result.
//
// Composition-as-source: the map carries its data + query as source. Reach
// compute ONLY through the src/data layer (getEngine) — exactly the pattern
// <grid-table> uses, generalized to the shared DuckDB engine. One engine, three
// surfaces: a table, a chart, and a map can all read the SAME registered source.
//
// Re-based onto Lit: render() returns the Lit shell (the stage + chrome + the
// pre-built SVG markup, dropped in via unsafeHTML — the drawing/projection code is
// ours); pan/zoom/select wiring lives in Lit's updated() hook. The _load
// single-flight + stable inline auto-name + whenRegistered/register plumbing is
// unchanged.
//
// Base layer (zero-dep, framework-agnostic): standalone, the map draws an
// ABSTRACT themed projection — points/regions projected to SVG with a chosen
// projection + a graticule, plus an optional slotted/inline vector world outline.
// Works with NO tile provider and NO network. Tile/basemap PIXELS are a keyed
// exception reached through the Host seam (this.host) when configured — see
// _tileLayerHint(); we never hard-depend on a tile CDN.
//
// Usage (inline points, declared lat/lon/value columns):
//   <map-view rows='[{"city":"Oslo","lat":59.9,"lon":10.7,"pop":700}]'
//           lat="lat" lon="lon" value="pop" mode="points"></map-view>
//
// Usage (register elsewhere, query a named source, aggregate in the engine):
//   <map-view src-name="quakes"
//           query="SELECT region, avg(lat) AS lat, avg(lon) AS lon, count(*) AS n
//                   FROM quakes GROUP BY region"
//           lat="lat" lon="lon" value="n" label="region" mode="choropleth"></map-view>
//
// Attributes:
//   rows        inline JSON array of row objects (auto-registers a source)
//   csv         inline CSV text (header row)
//   src-name    name of a source registered via getEngine().register(...)
//   query       full SQL to run (overrides the default SELECT * over src-name)
//   geojson     inline GeoJSON FeatureCollection (regions for choropleth);
//               may also be a slotted <script type="application/geo+json">
//   lat / lon   column names holding latitude / longitude (default "lat"/"lon")
//   value       column name driving size (points) / fill (choropleth)
//   label       column name for the feature label (tooltip / select detail)
//   key         column name matched to a GeoJSON feature property (choropleth)
//   geo-key     GeoJSON feature property matched to `key` (default: same as key)
//   projection  mercator | equirectangular   (default mercator)
//   mode        points | heat | choropleth    (the spatial-view variant)
//   variant     card | bare    (visual shell)
//   tiles       a tile-layer id reached via Host (e.g. "osm"); standalone if unset
//   engine      auto | maplibre | floor   (render tier — see below)
//
// TWO render tiers behind ONE public API (attrs / events / data path identical):
//   • FLOOR — the zero-dependency SVG projection above (points/heat/choropleth),
//     themed entirely from --work-*. The guaranteed render; never blocks on a net.
//   • POWERED — MapLibre GL (./maplibre-tier.js), lazy-loaded from a CDN ESM at
//     runtime (overridable via window.__WB_MAPLIBRE__). Renders the SAME features
//     from the SAME engine query — only the drawing/basemap changes. Real tiles
//     route through the Host (`this.host`, "tiles" cap); with no Host it draws a
//     token-themed blank/vector style (NO hardcoded CDN tile URL).
//   The tier resolves per-load: `engine="maplibre"|"floor"` attr or
//   window.__WB_MAP_ENGINE__ force it; default "auto" prefers MapLibre and falls
//   back to the floor instantly if the lazy import fails (offline / blocked).
//
// Events:
//   work-map-ready    { detail: { columns, types, engine, mode } }
//   work-map-query    { detail: { sql, rowCount, engine } }   on every (re)query
//   work-feature-select { detail: { feature, index } }        feature = row object
import { WbElement, html, css, define } from "../../core/element.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";
import { getEngine } from "../../data/index.js";
import { project, unproject, bounds } from "./projection.js";
import {
  loadMaplibre, loadMaplibreCss, readTokens, buildStyle,
  featuresToGeoJSON, addDataLayers,
} from "./maplibre-tier.js";

const VARIANTS = defineVariants({
  mode: { options: ["points", "heat", "choropleth"], default: "points" },
  variant: { options: ["card", "bare"], default: "card" },
  projection: { options: ["mercator", "equirectangular"], default: "mercator" },
});

let _autoId = 0;

export class WbMap extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "rows", "csv", "src-name", "query",
    "lat", "lon", "value", "label", "key", "geo-key", "geojson", "tiles",
    "engine",   // tier override: auto (default, prefer MapLibre) | maplibre | floor
  ];

  static styles = css`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell { position: relative; border: 1px solid var(--work-border);
      border-radius: var(--work-radius); background: var(--work-surface);
      overflow: hidden; box-shadow: var(--work-shadow-sm); }
    :host([variant="bare"]) .shell { border: none; box-shadow: none; background: transparent; }

    .stage { position: relative; width: 100%;
      height: var(--work-map-h, 460px); cursor: grab;
      background:
        radial-gradient(120% 120% at 50% -10%, var(--work-surface) 0%, var(--work-surface-soft) 100%); }
    .stage.dragging { cursor: grabbing; }
    svg { display: block; width: 100%; height: 100%; touch-action: none; user-select: none; }

    /* the POWERED tier host (MapLibre GL canvas). When it carries a child the
       floor SVG is declaratively hidden — no imperative show/hide race. */
    .gl { position: absolute; inset: 0; }
    .gl:empty { display: none; }
    .stage:has(.gl > *) > svg { visibility: hidden; }
    .gl .maplibregl-map { width: 100%; height: 100%; }

    /* the abstract themed basemap */
    .graticule { stroke: var(--work-border); stroke-width: var(--work-map-grid-w, 1); fill: none; opacity: .55; }
    .frame { stroke: var(--work-border-strong); stroke-width: 1; fill: none; opacity: .7; }
    .land { fill: var(--work-surface-soft); stroke: var(--work-border-strong); stroke-width: 1; opacity: .9; }

    /* choropleth regions (bound to query rows) */
    .region { stroke: var(--work-surface); stroke-width: 1; cursor: pointer;
      transition: filter var(--work-dur, .14s) var(--work-ease, ease); }
    .region:hover { filter: brightness(1.08); }
    .region[aria-selected="true"] { stroke: var(--work-fg); stroke-width: 2; }

    /* points / heat */
    .pt { fill: var(--work-brand); fill-opacity: .82; stroke: var(--work-surface); stroke-width: 1.2;
      cursor: pointer; transition: fill-opacity var(--work-dur,.14s) var(--work-ease,ease); }
    .pt:hover { fill-opacity: 1; }
    .pt[aria-selected="true"] { stroke: var(--work-fg); stroke-width: 2; }
    .heat { fill: var(--work-brand); }

    /* chrome */
    .toolbar { position: absolute; top: var(--work-space-2); left: var(--work-space-2);
      display: flex; align-items: center; gap: var(--work-space-2); z-index: 2; }
    .badge { display: inline-flex; align-items: center; gap: var(--work-space-1);
      font: 600 10px var(--work-font-mono); letter-spacing: .12em; text-transform: uppercase;
      color: var(--work-fg-muted); background: var(--work-surface); border: 1px solid var(--work-border);
      border-radius: var(--work-radius-pill); padding: var(--work-space-3px) var(--work-space-9px); box-shadow: var(--work-shadow-sm); }
    .engine .dot { width: 7px; height: 7px; border-radius: var(--work-radius-pill); background: var(--work-brand);
      box-shadow: 0 0 0 3px var(--work-brand-soft); }
    .engine[data-tier="memory"] .dot { background: var(--work-warn); box-shadow: 0 0 0 var(--work-space-3px) var(--work-warn-glow); }
    .engine[data-tier="error"] .dot { background: var(--work-err); box-shadow: none; }

    .zoom { position: absolute; top: var(--work-space-2); right: var(--work-space-2);
      display: flex; flex-direction: column; z-index: 2; box-shadow: var(--work-shadow-sm);
      border-radius: var(--work-radius-sm); overflow: hidden; border: 1px solid var(--work-border); }
    .zoom button { font: 600 15px var(--work-font-mono); width: 30px; height: 30px; line-height: 1;
      border: none; background: var(--work-surface); color: var(--work-fg); cursor: pointer; }
    .zoom button + button { border-top: 1px solid var(--work-border); }
    .zoom button:hover { background: var(--work-surface-soft); }

    .legend { position: absolute; bottom: var(--work-space-2); left: var(--work-space-2); z-index: 2;
      display: flex; align-items: center; gap: var(--work-space-2);
      font: 500 11px var(--work-font-mono); color: var(--work-fg-muted);
      background: var(--work-surface); border: 1px solid var(--work-border);
      border-radius: var(--work-radius-sm); padding: var(--work-space-1) var(--work-space-2); box-shadow: var(--work-shadow-sm); }
    .ramp { width: 96px; height: 8px; border-radius: var(--work-radius-pill);
      background: linear-gradient(90deg, var(--work-brand-soft), var(--work-brand)); }

    .tip { position: absolute; z-index: 3; pointer-events: none; transform: translate(-50%, -120%);
      background: var(--work-fg); color: var(--work-surface); font: 600 11px var(--work-font-mono);
      padding: var(--work-space-1) var(--work-space-2); border-radius: var(--work-radius-sm); white-space: nowrap;
      box-shadow: var(--work-shadow); opacity: 0; transition: opacity var(--work-dur,.14s); }
    .tip.show { opacity: 1; }

    .foot { display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-3); border-top: 1px solid var(--work-border);
      font-size: var(--work-text-sm); color: var(--work-fg-subtle); }
    .note { color: var(--work-fg-subtle); }
    .grow { flex: 1; }
    .empty { padding: var(--work-space-5); text-align: center; color: var(--work-fg-muted); font-size: var(--work-text-sm); }
  `;

  connectedCallback() {
    if (this._init == null) {
      this._init = true;
      this._engine = getEngine();
      this._result = null;
      this._tier = "memory";
      this._error = null;
      this._busy = true;
      this._sel = null;             // selected feature index
      this._view = { k: 1, x: 0, y: 0 }; // zoom factor + pan offset (plane units)
      this._features = [];          // projected, render-ready
      this._captureSource();
      this._captureGeojson();
    }
    super.connectedCallback();
    this._load();
    // The FLOOR re-themes automatically (token-driven CSS). The POWERED tier paints
    // onto a WebGL canvas where CSS tokens don't reach, so a theme flip must re-read
    // tokens + rebuild MapLibre's paint. Observe the documentElement theme attr and
    // redraw the powered tier when it changes (no-op when on the floor).
    if (typeof MutationObserver !== "undefined" && !this._themeObs) {
      this._themeObs = new MutationObserver(() => { if (this._map) { this._teardownPowered(); this._drawPowered(); } });
      this._themeObs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-work-theme", "class"] });
    }
  }

  disconnectedCallback() {
    this._teardownPowered();
    if (this._themeObs) { this._themeObs.disconnect(); this._themeObs = null; }
    super.disconnectedCallback();
  }

  _captureSource() {
    this._srcName = this.attr("src-name");
    if (!this._srcName) {
      const rowsAttr = this.attr("rows");
      const csvAttr = this.attr("csv");
      if (!this._autoName) this._autoName = `work_geo_${++_autoId}`;
      this._srcName = this._autoName;
      if (rowsAttr) this._pendingSource = { json: rowsAttr };
      else if (csvAttr) this._pendingSource = { csv: csvAttr };
      else {
        const text = this.textContent.trim();
        if (text.startsWith("[")) this._pendingSource = { json: text };
        else if (text.includes(",") && text.includes("\n")) this._pendingSource = { csv: text };
      }
    }
  }

  _captureGeojson() {
    // inline attr wins; else a slotted <script type="application/geo+json">.
    const inline = this.attr("geojson");
    if (inline) { this._geojson = safeJson(inline); return; }
    const slot = this.querySelector('script[type="application/geo+json"], script[type="application/json"][data-geojson]');
    this._geojson = slot ? safeJson(slot.textContent) : null;
  }

  attributeChangedCallback(name, old, val) {
    super.attributeChangedCallback(name, old, val);
    if (!this._init) return;
    if (name === "rows" || name === "csv" || name === "src-name" || name === "query") {
      this._pendingSource = null;
      this._captureSource();
      this._load();
    } else if (name === "geojson") {
      this._captureGeojson();
      this._rebuild();
      this.requestUpdate();
    } else {
      // lat/lon/value/label/key/mode/projection/variant — re-derive features
      this._rebuild();
      this.requestUpdate();
    }
  }

  async _load() {
    if (this._loading) { this._loadAgain = true; return; }
    this._loading = true;
    do {
      this._loadAgain = false;
      this._busy = true; this._error = null; this.requestUpdate();
      try {
        if (this._pendingSource) await this._engine.register(this._srcName, this._pendingSource);
        else if (this.hasAttribute("src-name")) await this._engine.whenRegistered(this._srcName);
        await this._run();
      } catch (e) {
        this._error = String((e && e.message) || e);
        this._tier = "error";
      }
      this._busy = false;
      this._rebuild();
      if (!this._fitted && this._features.length) { this._fit(); this._fitted = true; }
      this.requestUpdate();
      this._emit("work-map-ready", {
        columns: this._result?.columns || [], types: this._result?.types || [],
        engine: this._tier, mode: this.variant("mode"),
      });
    } while (this._loadAgain);
    this._loading = false;
  }

  async _run() {
    const sql = this._buildSql();
    this._result = await this._engine.query(sql);
    this._tier = this._result.engine || this._engine.provider();
    this._emit("work-map-query", { sql, rowCount: this._result.rowCount, engine: this._tier });
  }

  /** Spatial filtering/aggregation lives in SQL — we just pick the source/query. */
  _buildSql() {
    const base = this.attr("query");
    if (base) return base.replace(/;$/, "");
    return `SELECT * FROM ${ident(this._srcName)}`;
  }

  variant(name) {
    const def = VARIANTS[name];
    const v = this.getAttribute(name);
    return def && def.options.includes(v) ? v : def?.default;
  }

  // ── map {columns, rows[][], types} -> features ──────────────────────────────
  _rebuild() {
    this._features = [];
    const r = this._result;
    if (!r || !r.columns.length) return;
    const proj = this.variant("projection");
    const mode = this.variant("mode");
    const latC = colIdx(r, this.attr("lat", "lat"));
    const lonC = colIdx(r, this.attr("lon", "lon"));
    const valC = colIdx(r, this.attr("value"));
    const labC = colIdx(r, this.attr("label"));
    const keyC = colIdx(r, this.attr("key"));

    // value range (engine produced the numbers; we only scale to tokens here)
    let vMin = Infinity, vMax = -Infinity;
    if (valC >= 0) for (const row of r.rows) {
      const v = Number(row[valC]);
      if (!Number.isNaN(v)) { if (v < vMin) vMin = v; if (v > vMax) vMax = v; }
    }
    if (!isFinite(vMin)) { vMin = 0; vMax = 1; }
    this._vRange = [vMin, vMax];

    const rowObj = (i) => { const o = {}; r.columns.forEach((c, j) => (o[c] = r.rows[i][j])); return o; };

    if (mode === "choropleth" && this._geojson) {
      // True polygon choropleth: bind region ROWS to GeoJSON features by key.
      const geoKeyProp = this.attr("geo-key", this.attr("key"));
      const byKey = new Map();
      r.rows.forEach((row, i) => {
        const k = keyC >= 0 ? row[keyC] : (labC >= 0 ? row[labC] : i);
        byKey.set(String(k), { i, v: valC >= 0 ? Number(row[valC]) : null });
      });
      for (const f of (this._geojson.features || [])) {
        const k = geoKeyProp ? f.properties?.[geoKeyProp] : null;
        const hit = byKey.get(String(k));
        const rings = geometryToRings(f.geometry, proj);
        if (!rings.length) continue;
        this._features.push({
          kind: "region", rings,
          v: hit ? hit.v : null, i: hit ? hit.i : -1,
          row: hit ? rowObj(hit.i) : { ...f.properties },
        });
      }
      return;
    }

    // points / heat (and choropleth fallback = graduated bubbles at row coords)
    if (latC < 0 || lonC < 0) return;
    r.rows.forEach((row, i) => {
      const lat = Number(row[latC]), lon = Number(row[lonC]);
      if (Number.isNaN(lat) || Number.isNaN(lon)) return;
      const [x, y] = project(lon, lat, proj);
      this._features.push({
        kind: "point", x, y, lat, lon,
        v: valC >= 0 ? Number(row[valC]) : null,
        label: labC >= 0 ? row[labC] : null,
        i, row: rowObj(i),
      });
    });
  }

  // ── view transform (pan/zoom over the normalized plane) ─────────────────────
  _fit() {
    // Fit the data (or whole world) into the unit plane, then center it.
    const pts = this._features.flatMap((f) => f.kind === "point" ? [[f.lon, f.lat]] :
      f.rings.flatMap((rg) => rg)); // region rings already in plane coords below
    if (this.variant("mode") === "choropleth" && this._geojson) {
      // rings are already plane coords; compute bbox directly
      let minX = 1, minY = 1, maxX = 0, maxY = 0;
      for (const f of this._features) for (const rg of f.rings) for (const [x, y] of rg) {
        if (x < minX) minX = x; if (y < minY) minY = y;
        if (x > maxX) maxX = x; if (y > maxY) maxY = y;
      }
      if (maxX <= minX) return;
      this._applyFit(minX, minY, maxX, maxY);
      return;
    }
    if (pts.length) {
      const b = bounds(pts, this.variant("projection"));
      this._applyFit(b.minX, b.minY, b.maxX, b.maxY);
    }
  }

  _applyFit(minX, minY, maxX, maxY) {
    const padX = (maxX - minX) * 0.12 + 0.02, padY = (maxY - minY) * 0.12 + 0.02;
    minX -= padX; maxX += padX; minY -= padY; maxY += padY;
    const w = Math.max(maxX - minX, 1e-3), h = Math.max(maxY - minY, 1e-3);
    const k = Math.min(1 / w, 1 / h);
    this._view = { k, x: -minX * k, y: -minY * k };
  }

  // ── render ──────────────────────────────────────────────────────────────────
  render() {
    const mode = this.variant("mode");
    const tierText = this._busy ? "querying…" : this._error ? "engine error" :
      this._tier === "runtime" ? "engine: runtime DuckDB" :
      this._tier === "duckdb-wasm" ? "engine: DuckDB-wasm (in-browser)" :
      "engine: in-JS (offline)";
    const baseText = this.attr("tiles")
      ? `basemap: ${esc(this.attr("tiles"))} (via Host)` : "basemap: abstract (standalone)";

    let body;
    if (this._busy && !this._result) body = `<div class="stage"><div class="empty">Loading…</div></div>`;
    else if (this._error) body = `<div class="stage"><div class="empty">${esc(this._error)}</div></div>`;
    else if (!this._features.length) body = `<div class="stage"><div class="empty">No spatial rows.</div></div>`;
    else body = this._renderStage(mode);

    const shell = `<div class="shell">
      ${body}
      <div class="foot">
        <span class="note">${esc(tierText)}</span>
        <span class="note">· ${esc(baseText)}</span>
        ${this._result ? `<span class="grow"></span><span class="note">${this._features.length.toLocaleString()} features</span>` : ""}
      </div>
    </div>`;
    return html`${unsafeHTML(shell)}`;
  }

  _renderStage(mode) {
    const VB = 1000; // viewBox px per plane unit
    const { k, x, y } = this._view;
    // SVG transform: plane[0..1] -> screen, with view pan/zoom.
    const t = `translate(${x * VB} ${y * VB}) scale(${k})`;
    const grat = this._graticule(VB);
    const land = this._landPaths(t, VB);
    const layer = mode === "choropleth" && this._geojson
      ? this._renderRegions(VB) : mode === "heat" ? this._renderHeat(VB)
      : mode === "choropleth" ? this._renderBubbles(VB) : this._renderPoints(VB);

    const legend = (this.attr("value") != null && mode !== "points")
      ? `<div class="legend"><span>${esc(this.attr("value"))}</span><span class="ramp"></span>
           <span>${fmtNum(this._vRange[1])}</span></div>` : "";

    return `<div class="stage">
      <div class="toolbar">
        <span class="badge engine" data-tier="${this._error ? "error" : this._tier}"><span class="dot"></span>${esc(mode)}</span>
      </div>
      <div class="zoom"><button data-z="in" aria-label="zoom in">+</button><button data-z="out" aria-label="zoom out">−</button></div>
      ${legend}
      <div class="tip" id="tip"></div>
      <svg viewBox="0 0 ${VB} ${VB}" preserveAspectRatio="xMidYMid slice">
        <g class="basemap" transform="${t}">
          ${grat}
          ${land}
        </g>
        <g class="data" transform="${t}">
          ${layer}
        </g>
      </svg>
      <div class="gl" part="gl"></div>
    </div>`;
  }

  _graticule(VB) {
    // lon/lat grid + a frame, in plane coords (the abstract themed basemap).
    const proj = this.variant("projection");
    const lines = [];
    for (let lon = -180; lon <= 180; lon += 30) {
      const seg = [];
      for (let lat = -85; lat <= 85; lat += 5) { const [px, py] = project(lon, lat, proj); seg.push(`${px * VB},${py * VB}`); }
      lines.push(`<polyline class="graticule" points="${seg.join(" ")}" />`);
    }
    for (let lat = -60; lat <= 60; lat += 30) {
      const seg = [];
      for (let lon = -180; lon <= 180; lon += 10) { const [px, py] = project(lon, lat, proj); seg.push(`${px * VB},${py * VB}`); }
      lines.push(`<polyline class="graticule" points="${seg.join(" ")}" />`);
    }
    const [x0, y0] = project(-180, 85, proj), [x1, y1] = project(180, -85, proj);
    lines.push(`<rect class="frame" x="${x0 * VB}" y="${y0 * VB}" width="${(x1 - x0) * VB}" height="${(y1 - y0) * VB}" />`);
    return lines.join("");
  }

  _landPaths(_t, VB) {
    // Optional slotted/inline world outline (when NOT used as choropleth source).
    if (this.variant("mode") === "choropleth" && this._geojson) return "";
    if (!this._geojson) return "";
    const proj = this.variant("projection");
    let d = "";
    for (const f of (this._geojson.features || [])) {
      for (const rg of geometryToRings(f.geometry, proj)) {
        d += "M" + rg.map(([px, py]) => `${(px * VB).toFixed(1)} ${(py * VB).toFixed(1)}`).join("L") + "Z";
      }
    }
    return d ? `<path class="land" d="${d}" />` : "";
  }

  _renderPoints(VB) {
    const r = 6 / Math.max(this._view.k, 1); // keep markers readable while zoomed
    return this._features.map((f) => {
      const rr = f.v != null ? r * (0.5 + this._scale(f.v)) : r;
      return `<circle class="pt" data-i="${f.i}" cx="${(f.x * VB).toFixed(1)}" cy="${(f.y * VB).toFixed(1)}"
        r="${rr.toFixed(2)}" ${this._sel === f.i ? 'aria-selected="true"' : ""} />`;
    }).join("");
  }

  _renderBubbles(VB) {
    // choropleth WITHOUT GeoJSON = graduated proportional bubbles (the standalone
    // floor; the engine still did the GROUP BY that produced these rows).
    const base = 26 / Math.max(this._view.k, 1);
    return this._features
      .slice().sort((a, b) => (b.v || 0) - (a.v || 0))
      .map((f) => {
        const rr = base * (0.25 + this._scale(f.v));
        const fill = this._fillFor(f.v);
        return `<circle class="pt" style="fill:${fill};fill-opacity:.62" data-i="${f.i}"
          cx="${(f.x * VB).toFixed(1)}" cy="${(f.y * VB).toFixed(1)}" r="${rr.toFixed(2)}"
          ${this._sel === f.i ? 'aria-selected="true"' : ""} />`;
      }).join("");
  }

  _renderHeat(VB) {
    // Lightweight heat: stacked translucent radial blooms (no shader, no dep).
    const base = 40 / Math.max(this._view.k, 1);
    return this._features.map((f) => {
      const rr = base * (0.4 + this._scale(f.v));
      const op = (0.12 + 0.5 * this._scale(f.v)).toFixed(2);
      return `<circle class="heat" data-i="${f.i}" cx="${(f.x * VB).toFixed(1)}" cy="${(f.y * VB).toFixed(1)}"
        r="${rr.toFixed(1)}" style="fill-opacity:${op}" />`;
    }).join("");
  }

  _renderRegions(VB) {
    return this._features.map((f) => {
      const d = f.rings.map((rg) => "M" + rg.map(([px, py]) => `${(px * VB).toFixed(1)} ${(py * VB).toFixed(1)}`).join("L") + "Z").join("");
      const fill = f.v == null ? "var(--work-surface-soft)" : this._fillFor(f.v);
      return `<path class="region" data-i="${f.i}" d="${d}" style="fill:${fill}"
        ${this._sel === f.i ? 'aria-selected="true"' : ""} />`;
    }).join("");
  }

  /** Normalize a value into [0..1] across the engine-computed range. */
  _scale(v) {
    if (v == null || Number.isNaN(+v)) return 0.4;
    const [lo, hi] = this._vRange;
    if (hi <= lo) return 0.6;
    return Math.sqrt((+v - lo) / (hi - lo)); // sqrt -> area-fair point sizing
  }

  /** Token-only choropleth fill: blend toward --work-brand by value (via opacity). */
  _fillFor(v) {
    const t = this._scale(v);
    // color-mix keeps everything token-driven; falls back to brand if unsupported.
    return `color-mix(in srgb, var(--work-brand) ${Math.round(15 + t * 85)}%, var(--work-surface-soft))`;
  }

  /** Documented Host path for real basemap PIXELS (a keyed exception). */
  _tileLayerHint() {
    const id = this.attr("tiles");
    if (!id || !this.host?.available?.("tiles")) return null;
    // A Host that exposes "tiles" brokers PMTiles/tile requests; the element would
    // request tile URLs through this.host.request("/maps/tiles", …) and draw them
    // UNDER the data layer. Standalone (no tiles attr / no Host cap) we never reach
    // a CDN — the abstract projection above is the basemap. (Wiring lands with the
    // PMTiles broker; the data binding is the reinvention, not a Leaflet clone.)
    return id;
  }

  // ── tier resolution (mirrors wb-chart's _tierChoice) ──────────────────────────
  // floor (zero-dep SVG projection) vs maplibre (MapLibre GL).
  //   - attribute engine="floor" | "maplibre" forces it (the gate drives this)
  //   - window.__WB_MAP_ENGINE__ = "floor" | "maplibre" is the host opt-out
  //   - default "auto": prefer MapLibre when it loads, fall back to the floor.
  _tierChoice() {
    const attr = this.attr("engine");
    if (attr === "floor" || attr === "maplibre") return attr;
    const host = typeof window !== "undefined" && window.__WB_MAP_ENGINE__;
    if (host === "floor" || host === "maplibre") return host;
    return "auto";
  }

  /**
   * Resolve a MapLibre tile source spec through the Host (a keyed exception). With
   * no Host "tiles" capability we return null → MapLibre renders the token-themed
   * blank style (NO hardcoded CDN tile URL — keeps the offline/wasm gate green).
   */
  _resolveTileSource() {
    const id = this.attr("tiles");
    if (!id || !this.host?.available?.("tiles")) return null;
    try { return this.host.tileSource?.(id) || null; } catch { return null; }
  }

  // The POWERED tier — MapLibre GL, lazy-loaded. On success it draws the SAME
  // features into the .gl host (the floor SVG is hidden declaratively by CSS). On
  // failure (network-blocked / load error) it leaves the floor in place — forced
  // engine="maplibre" still degrades gracefully; the floor IS the guaranteed
  // render (the wasm/floor gate proves this).
  async _drawPowered() {
    const gl = this.shadowRoot && this.shadowRoot.querySelector(".gl");
    if (!gl || !this._features.length) return;
    const token = (this._glToken = (this._glToken || 0) + 1);
    let ml;
    try { ml = await loadMaplibre(); }
    catch { return; /* floor already drawn — graceful degrade */ }
    if (token !== this._glToken || !this.isConnected) return;
    this._ML = ml;

    // gate-b: adopt MapLibre's stylesheet into the SHADOW root (constructable
    // sheet), never document.head. Best-effort.
    try {
      if (!this._mlSheet) {
        const cssText = await loadMaplibreCss();
        if (cssText) {
          this._mlSheet = new CSSStyleSheet();
          this._mlSheet.replaceSync(cssText);
          this.shadowRoot.adoptedStyleSheets = [...this.shadowRoot.adoptedStyleSheets, this._mlSheet];
        }
      }
    } catch {}
    if (token !== this._glToken) return;

    const tk = readTokens(this);
    const projKind = this.variant("projection");
    const geojson = featuresToGeoJSON(this._features, unproject, projKind);
    const tileSource = this._resolveTileSource();

    if (!this._map) {
      try {
        this._map = new ml.Map({
          container: gl,
          style: buildStyle(tk, tileSource),
          attributionControl: false,
          interactive: true,
        });
      } catch (e) { this._map = null; return; }
      const onReady = () => {
        if (token !== this._glToken) { try { this._map.remove(); } catch {} this._map = null; return; }
        // the .gl container only gets its real box after shadow layout — resize so
        // MapLibre's canvas matches the stage before we fit the data bounds.
        try { this._map.resize(); } catch {}
        addDataLayers(this._map, this.variant("mode"), geojson, this._features, tk);
        this._fitMapLibre(geojson, projKind);
        this._wireMapLibreSelect();
        this._emit("work-map-engine", { engine: "maplibre" });
      };
      if (this._map.loaded && this._map.loaded()) onReady();
      else this._map.on("load", onReady);
    } else {
      this._map.setStyle(buildStyle(tk, tileSource));
      const reAdd = () => {
        addDataLayers(this._map, this.variant("mode"), geojson, this._features, tk);
        this._wireMapLibreSelect();
      };
      if (this._map.isStyleLoaded && this._map.isStyleLoaded()) reAdd();
      else this._map.once("styledata", reAdd);
    }
  }

  // Fit the MapLibre viewport to the data's lon/lat bbox (mirrors floor _fit).
  _fitMapLibre(geojson, projKind) {
    let minLon = 180, minLat = 90, maxLon = -180, maxLat = -90, any = false;
    const eat = (lon, lat) => { any = true;
      if (lon < minLon) minLon = lon; if (lon > maxLon) maxLon = lon;
      if (lat < minLat) minLat = lat; if (lat > maxLat) maxLat = lat; };
    for (const f of geojson.features) {
      if (f.geometry.type === "Point") eat(...f.geometry.coordinates);
      else if (f.geometry.type === "Polygon") for (const ring of f.geometry.coordinates) for (const [lo, la] of ring) eat(lo, la);
    }
    if (!any) return;
    try { this._map.fitBounds([[minLon, minLat], [maxLon, maxLat]], { padding: 36, duration: 0, maxZoom: 6 }); } catch {}
  }

  // Forward MapLibre feature clicks to the SAME work-feature-select contract.
  _wireMapLibreSelect() {
    if (!this._map || this._mlWired) return;
    this._mlWired = true;
    for (const layer of ["wb-points", "wb-regions"]) {
      this._map.on("click", layer, (e) => {
        const feat = e.features && e.features[0];
        if (!feat) return;
        const fi = feat.properties?._fi;
        const ff = this._features.find((x) => x.i === fi);
        this._sel = fi;
        if (ff) this._emit("work-feature-select", { feature: ff.row, index: fi });
      });
      this._map.on("mouseenter", layer, () => { this._map.getCanvas().style.cursor = "pointer"; });
      this._map.on("mouseleave", layer, () => { this._map.getCanvas().style.cursor = ""; });
    }
  }

  // Tear the MapLibre map down (engine flip to floor, or disconnect).
  _teardownPowered() {
    this._glToken = (this._glToken || 0) + 1; // invalidate any in-flight draw
    if (this._map) { try { this._map.remove(); } catch {} this._map = null; }
    this._mlWired = false;
    const gl = this.shadowRoot && this.shadowRoot.querySelector(".gl");
    if (gl) gl.innerHTML = "";
  }

  // Lit lifecycle: the shell just (re)rendered — (re)wire pan/zoom/select. Old
  // listeners die with the replaced nodes (unsafeHTML rebuilds the markup).
  updated() {
    const root = this.shadowRoot;
    const stage = root.querySelector(".stage");
    const svg = root.querySelector("svg");
    const tip = root.querySelector("#tip");
    if (!svg) return;

    // tier dispatch: the floor SVG is ALWAYS wired below (the guaranteed render +
    // instant fallback). When MapLibre is chosen we additionally draw it into the
    // .gl host (CSS hides the floor svg once it has a child). unsafeHTML rebuilt
    // the .gl node each render, so re-mount the powered tier here.
    const choice = this._tierChoice();
    if (choice === "floor") {
      this._teardownPowered();
    } else if (this._features.length) {
      this._teardownPowered();   // fresh .gl node → drop old map, redraw into new
      this._drawPowered();
    }

    // pan (drag)
    let dragging = false, sx = 0, sy = 0, ox = 0, oy = 0;
    const VB = 1000;
    svg.addEventListener("pointerdown", (e) => {
      dragging = true; stage.classList.add("dragging");
      sx = e.clientX; sy = e.clientY; ox = this._view.x; oy = this._view.y;
      svg.setPointerCapture?.(e.pointerId);
    });
    svg.addEventListener("pointermove", (e) => {
      if (!dragging) return;
      const rect = svg.getBoundingClientRect();
      this._view.x = ox + (e.clientX - sx) / (rect.width || 1);
      this._view.y = oy + (e.clientY - sy) / (rect.height || 1) * (rect.height / rect.width);
      this._applyTransform();
    });
    const end = () => { dragging = false; stage.classList.remove("dragging"); };
    svg.addEventListener("pointerup", end);
    svg.addEventListener("pointerleave", end);

    // zoom (wheel + buttons), centered on cursor
    svg.addEventListener("wheel", (e) => {
      e.preventDefault();
      this._zoomAt(e.deltaY < 0 ? 1.18 : 1 / 1.18, e, svg);
    }, { passive: false });
    root.querySelectorAll(".zoom button").forEach((b) =>
      b.addEventListener("click", () => this._zoomCenter(b.dataset.z === "in" ? 1.4 : 1 / 1.4)));

    // feature select + tooltip
    root.querySelectorAll("[data-i]").forEach((el) => {
      const i = +el.getAttribute("data-i");
      el.addEventListener("click", (e) => { e.stopPropagation(); this._select(i); });
      el.addEventListener("pointerenter", (e) => this._showTip(i, e, tip, svg));
      el.addEventListener("pointermove", (e) => this._moveTip(e, tip, svg));
      el.addEventListener("pointerleave", () => tip && tip.classList.remove("show"));
    });
    svg.addEventListener("click", () => this._select(null));
  }

  _applyTransform() {
    const { k, x, y } = this._view, VB = 1000;
    const t = `translate(${x * VB} ${y * VB}) scale(${k})`;
    this.shadowRoot.querySelectorAll("svg > g").forEach((g) => g.setAttribute("transform", t));
  }

  _zoomCenter(factor) {
    const k0 = this._view.k, k1 = clamp(k0 * factor, 0.5, 60);
    // zoom about plane-center of current view
    const cx = (0.5 - this._view.x) / k0, cy = (0.5 - this._view.y) / k0;
    this._view.k = k1;
    this._view.x = 0.5 - cx * k1;
    this._view.y = 0.5 - cy * k1;
    this.requestUpdate(); // re-render so marker radii rescale crisply
  }

  _zoomAt(factor, e, svg) {
    const rect = svg.getBoundingClientRect();
    const fx = (e.clientX - rect.left) / (rect.width || 1);
    const fy = (e.clientY - rect.top) / (rect.height || 1);
    const k0 = this._view.k, k1 = clamp(k0 * factor, 0.5, 60);
    const px = (fx - this._view.x) / k0, py = (fy - this._view.y) / k0;
    this._view.k = k1;
    this._view.x = fx - px * k1;
    this._view.y = fy - py * k1;
    this.requestUpdate();
  }

  _select(i) {
    this._sel = i;
    const f = i == null ? null : this._features.find((ft) => ft.i === i);
    this._applySelectionAttrs();
    if (f) this._emit("work-feature-select", { feature: f.row, index: i });
  }

  _applySelectionAttrs() {
    this.shadowRoot.querySelectorAll("[data-i]").forEach((el) => {
      if (+el.getAttribute("data-i") === this._sel) el.setAttribute("aria-selected", "true");
      else el.removeAttribute("aria-selected");
    });
  }

  _tipText(f) {
    if (!f) return "";
    const lab = f.label != null ? String(f.label)
      : f.row && (f.row[this.attr("label")] ?? f.row[this.attr("key")]);
    const v = f.v != null && !Number.isNaN(+f.v) ? `${this.attr("value") || "value"}: ${fmtNum(f.v)}` : "";
    return [lab, v].filter(Boolean).join(" · ") || `#${f.i}`;
  }

  _showTip(i, e, tip, svg) {
    const f = this._features.find((ft) => ft.i === i);
    if (!tip || !f) return;
    tip.textContent = this._tipText(f);
    tip.classList.add("show");
    this._moveTip(e, tip, svg);
  }
  _moveTip(e, tip, svg) {
    if (!tip || !tip.classList.contains("show")) return;
    const rect = svg.getBoundingClientRect();
    tip.style.left = `${e.clientX - rect.left}px`;
    tip.style.top = `${e.clientY - rect.top}px`;
  }

  _emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }
}

// ── helpers (token-unaware) ────────────────────────────────────────────────────
function ident(name) { return '"' + String(name).replace(/"/g, '""') + '"'; }
function colIdx(r, name) { return name == null ? -1 : r.columns.indexOf(name); }
function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
function fmtNum(v) {
  if (v == null || Number.isNaN(+v)) return "";
  const n = +v;
  return Number.isInteger(n) ? n.toLocaleString() : n.toLocaleString(undefined, { maximumFractionDigits: 2 });
}
function safeJson(s) { try { return JSON.parse(s); } catch { return null; } }

/** GeoJSON geometry -> array of rings, each ring an array of projected [x,y]. */
function geometryToRings(geom, proj) {
  if (!geom) return [];
  const ringsOf = (coords) => coords.map((ring) => ring.map(([lon, lat]) => project(lon, lat, proj)));
  if (geom.type === "Polygon") return ringsOf(geom.coordinates);
  if (geom.type === "MultiPolygon") return geom.coordinates.flatMap((poly) => ringsOf(poly));
  return [];
}

define("map-view", WbMap);
