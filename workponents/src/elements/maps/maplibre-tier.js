// maps · the POWERED tier — MapLibre GL behind the <map-view> floor.
//
// The floor (wb-map.js `_renderPoints`/`_renderHeat`/`_renderBubbles`/
// `_renderRegions`) is a zero-dependency SVG projection themed entirely from
// --work-*. This module is the powered alternative: it draws the SAME logical
// features (the SAME points / regions off the SAME engine query result) with a
// real MapLibre GL map — only the drawing/basemap changes, never the public API
// or the data path.
//
// Lazy-loaded from a CDN ESM at runtime (mirrors plot-tier.js / sqlite-wasm /
// wavelet): nothing is bundled, no dep is installed. `loadMaplibre()` is a
// single-flight import() resolving to the MapLibre namespace, overridable via
// `window.__WB_MAPLIBRE__` (tests / offline hosts inject their own). If the
// import fails (network-blocked — the gate's wasm/floor proof), the caller
// silently falls back to the floor SVG.
//
// BASEMAP via Host (gate-c, offline): we NEVER hardcode a CDN tile URL — that
// would fail the wasm/offline gate. With a Host that exposes the "tiles"
// capability (PMTiles / tile broker), real tile sources route through it. With
// NO Host, MapLibre renders a token-themed BLANK / vector style (background +
// the projected feature layers) — fully offline.
//
// THEMING (gate-a, token-leak): MapLibre ships its own default colors + injects
// its own <style>. We never let a literal leak — every color MapLibre paints
// (background/water/land/labels + the feature layers) is READ from the element's
// computed --work-* tokens (readTokens) and passed into the MapLibre style spec.
// Flip the theme → re-read tokens → re-apply paint → the map re-themes exactly
// like the floor.
//
// SCOPE (gate-b): MapLibre injects a global <style> into document.head by
// default. We force it SHADOW-scoped: before constructing the map we point
// MapLibre's stylesheet at our shadow root (it appends its CSS into the map
// container's root node when that node is a ShadowRoot), and we adopt MapLibre's
// stylesheet text into the element's own constructable stylesheet so nothing
// lands in document.head.

const MAPLIBRE_CDN = "https://esm.sh/maplibre-gl@4";
const MAPLIBRE_CSS_CDN = "https://esm.sh/maplibre-gl@4/dist/maplibre-gl.css";

let _mlPromise = null;
let _cssPromise = null;

/**
 * Single-flight lazy import of MapLibre GL. Resolves to the MapLibre namespace
 * (the module's default or `{ Map, ... }`). Overridable for tests / offline hosts
 * via `window.__WB_MAPLIBRE__`. Rejects when the chunk can't load — the caller
 * falls back to the floor.
 */
export function loadMaplibre() {
  const override = typeof window !== "undefined" && window.__WB_MAPLIBRE__;
  if (override) return Promise.resolve(override);
  if (!_mlPromise) {
    _mlPromise = import(/* @vite-ignore */ MAPLIBRE_CDN)
      .then((m) => m.default || m)
      .catch((e) => {
        _mlPromise = null; // allow a later retry
        throw e;
      });
  }
  return _mlPromise;
}

/**
 * Fetch MapLibre's stylesheet TEXT so we can adopt it shadow-scoped (gate-b) —
 * never a <link> in document.head. Best-effort: a failure just means the map
 * draws without MapLibre's control chrome CSS (the canvas itself is unaffected).
 * Skipped entirely when an override (shim) is active.
 */
function loadMaplibreCss() {
  if (typeof window !== "undefined" && window.__WB_MAPLIBRE__) return Promise.resolve("");
  if (!_cssPromise) {
    _cssPromise = fetch(MAPLIBRE_CSS_CDN).then((r) => (r.ok ? r.text() : "")).catch(() => "");
  }
  return _cssPromise;
}

// Read the resolved --work-* token VALUES off the element (computed style).
// MapLibre's style spec wants concrete colors, never `var(--work-*)` strings (it
// paints onto a WebGL canvas where the CSS cascade does not reach). Reading the
// computed value keeps MapLibre's paint locked to the active theme — flip the
// theme, re-read, re-apply → the map re-themes (the flip-delta gate passes).
export function readTokens(el) {
  const cs = getComputedStyle(el);
  const v = (name, fallback) => (cs.getPropertyValue(name).trim() || fallback);
  return {
    fg:        v("--work-fg", "#121316"),
    fgMuted:   v("--work-fg-muted", "rgba(18,19,22,0.6)"),
    fgSubtle:  v("--work-fg-subtle", "rgba(18,19,22,0.38)"),
    surface:   v("--work-surface", "#ffffff"),
    surfaceSoft: v("--work-surface-soft", "#efede6"),
    border:    v("--work-border", "rgba(18,19,22,0.13)"),
    borderStrong: v("--work-border-strong", "rgba(18,19,22,0.28)"),
    brand:     v("--work-brand", "#13d943"),
    brandSoft: v("--work-brand-soft", "rgba(19,217,67,0.13)"),
    font:      v("--work-font", "system-ui, sans-serif"),
  };
}

/**
 * Build the MapLibre style spec from tokens — a token-themed BLANK/vector style.
 * NO hardcoded CDN tile URL: the background + graticule/land come from token
 * colors; the actual data features are added as separate GeoJSON sources/layers
 * after the map loads. When `tileSource` is provided (resolved via Host) it is
 * spliced in UNDER the data layers as the real basemap.
 *
 * @param tk          readTokens(el)
 * @param tileSource  optional MapLibre source spec from the Host tile broker
 */
export function buildStyle(tk, tileSource) {
  const sources = {};
  const layers = [
    // token-themed "water" / page backdrop — the blank basemap floor.
    { id: "wb-bg", type: "background", paint: { "background-color": tk.surface } },
  ];
  if (tileSource) {
    sources["wb-tiles"] = tileSource;
    layers.push(
      tileSource.type === "raster"
        ? { id: "wb-basemap", type: "raster", source: "wb-tiles" }
        : { id: "wb-basemap", type: "fill", source: "wb-tiles", "source-layer": "land",
            paint: { "fill-color": tk.surfaceSoft, "fill-outline-color": tk.border } },
    );
  }
  // a sprite-less / glyph-less style — no external fetch (omit glyphs entirely;
  // MapLibre rejects an explicit `undefined`). We render no symbol/label layers,
  // so the missing glyph endpoint is never reached — fully offline-safe.
  return { version: 8, sources, layers };
}

/** Engine value range → [min,max] for token-driven scaling (mirrors floor). */
function valueRange(features) {
  let lo = Infinity, hi = -Infinity;
  for (const f of features) {
    if (f.v == null || Number.isNaN(+f.v)) continue;
    if (+f.v < lo) lo = +f.v;
    if (+f.v > hi) hi = +f.v;
  }
  if (!isFinite(lo)) return [0, 1];
  return [lo, hi];
}

/**
 * Convert the floor's projected feature list into a GeoJSON FeatureCollection in
 * lon/lat (MapLibre's native coordinate space). Points carry their original
 * lat/lon; regions are unprojected back to lon/lat from their plane rings via the
 * supplied `unproject`. The `_fi` property is the floor feature index `f.i` so
 * MapLibre selection maps back to the SAME work-feature-select contract.
 *
 * @param features  el._features (the floor's render-ready model)
 * @param unproject (x,y,kind)->[lon,lat]
 * @param projKind  "mercator" | "equirectangular"
 */
export function featuresToGeoJSON(features, unproject, projKind) {
  const out = { type: "FeatureCollection", features: [] };
  for (const f of features) {
    if (f.kind === "point") {
      out.features.push({
        type: "Feature",
        properties: { _fi: f.i, _v: f.v == null ? null : +f.v, _label: f.label == null ? null : String(f.label) },
        geometry: { type: "Point", coordinates: [f.lon, f.lat] },
      });
    } else if (f.kind === "region") {
      const rings = f.rings.map((rg) => rg.map(([x, y]) => unproject(x, y, projKind)));
      out.features.push({
        type: "Feature",
        properties: { _fi: f.i, _v: f.v == null ? null : +f.v },
        geometry: { type: "Polygon", coordinates: rings },
      });
    }
  }
  return out;
}

/**
 * Add the data layers (points / heat / choropleth) to a loaded MapLibre map,
 * styled from tokens. Returns the value range used (for the caller's legend).
 *
 * @param map      the MapLibre Map instance
 * @param mode     "points" | "heat" | "choropleth"
 * @param geojson  featuresToGeoJSON(...)
 * @param features el._features (for the value range)
 * @param tk       readTokens(el)
 */
export function addDataLayers(map, mode, geojson, features, tk) {
  const [lo, hi] = valueRange(features);
  const hasVal = hi > lo;
  if (map.getSource("wb-data")) {
    try { map.removeLayer("wb-points"); } catch {}
    try { map.removeLayer("wb-heat"); } catch {}
    try { map.removeLayer("wb-regions"); } catch {}
    try { map.removeLayer("wb-regions-line"); } catch {}
    map.getSource("wb-data").setData(geojson);
  } else {
    map.addSource("wb-data", { type: "geojson", data: geojson });
  }

  if (mode === "heat") {
    map.addLayer({
      id: "wb-heat", type: "heatmap", source: "wb-data",
      paint: {
        "heatmap-weight": hasVal
          ? ["interpolate", ["linear"], ["coalesce", ["get", "_v"], lo], lo, 0.2, hi, 1]
          : 0.6,
        "heatmap-radius": 32,
        "heatmap-opacity": 0.85,
        // token-driven ramp: transparent → brand-soft → brand.
        "heatmap-color": [
          "interpolate", ["linear"], ["heatmap-density"],
          0, "rgba(0,0,0,0)",
          0.4, tk.brandSoft,
          1, tk.brand,
        ],
      },
    });
  } else if (mode === "choropleth") {
    // regions (polygons) when present, else graduated bubbles at point coords.
    const hasPolys = geojson.features.some((f) => f.geometry.type === "Polygon");
    if (hasPolys) {
      map.addLayer({
        id: "wb-regions", type: "fill", source: "wb-data",
        filter: ["==", ["geometry-type"], "Polygon"],
        paint: {
          "fill-color": hasVal
            ? ["interpolate", ["linear"], ["coalesce", ["get", "_v"], lo], lo, tk.surfaceSoft, hi, tk.brand]
            : tk.surfaceSoft,
          "fill-opacity": 0.85,
          "fill-outline-color": tk.surface,
        },
      });
      map.addLayer({
        id: "wb-regions-line", type: "line", source: "wb-data",
        filter: ["==", ["geometry-type"], "Polygon"],
        paint: { "line-color": tk.border, "line-width": 1 },
      });
    } else {
      map.addLayer({
        id: "wb-points", type: "circle", source: "wb-data",
        filter: ["==", ["geometry-type"], "Point"],
        paint: {
          "circle-radius": hasVal
            ? ["interpolate", ["linear"], ["sqrt", ["max", ["coalesce", ["get", "_v"], lo], 0.0001]],
               Math.sqrt(Math.max(lo, 0.0001)), 6, Math.sqrt(Math.max(hi, 0.0001)), 26]
            : 8,
          "circle-color": hasVal
            ? ["interpolate", ["linear"], ["coalesce", ["get", "_v"], lo], lo, tk.surfaceSoft, hi, tk.brand]
            : tk.brand,
          "circle-opacity": 0.62,
          "circle-stroke-color": tk.surface,
          "circle-stroke-width": 1,
        },
      });
    }
  } else {
    // points
    map.addLayer({
      id: "wb-points", type: "circle", source: "wb-data",
      filter: ["==", ["geometry-type"], "Point"],
      paint: {
        "circle-radius": hasVal
          ? ["interpolate", ["linear"], ["sqrt", ["max", ["coalesce", ["get", "_v"], lo], 0.0001]],
             Math.sqrt(Math.max(lo, 0.0001)), 4, Math.sqrt(Math.max(hi, 0.0001)), 14]
          : 6,
        "circle-color": tk.brand,
        "circle-opacity": 0.82,
        "circle-stroke-color": tk.surface,
        "circle-stroke-width": 1.2,
      },
    });
  }
  return [lo, hi];
}

/**
 * Re-apply token colors to an existing map's layers (theme flip) without
 * rebuilding the map. Reads paint props that exist; missing layers are skipped.
 */
export function applyTheme(map, mode, tk) {
  if (!map || !map.getLayer) return;
  const set = (layer, prop, val) => { try { if (map.getLayer(layer)) map.setPaintProperty(layer, prop, val); } catch {} };
  set("wb-bg", "background-color", tk.surface);
  set("wb-points", "circle-stroke-color", tk.surface);
  set("wb-regions-line", "line-color", tk.border);
  // the value-driven ramps already encode token colors at build time; for a flip
  // we rebuild the data layers from the caller (re-read tokens), so this covers
  // the static (non-value) paints that don't get rebuilt.
}

export { MAPLIBRE_CDN, loadMaplibreCss };
