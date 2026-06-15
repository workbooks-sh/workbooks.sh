// workponents · maps domain — the map IS a SPATIAL VIEW OVER A QUERY. Points and
// regions come from query ROWS (lat/lon/value columns of a WbQueryResult), not a
// hand-fed GeoJSON blob. Spatial filtering + aggregation run IN the shared DuckDB
// engine (runtime tier · browser duckdb-wasm · in-JS offline floor) — reach
// compute only through ../../data. One engine, three surfaces: tables / data-viz
// / maps can read the SAME registered source.
//
// Standalone + framework-agnostic: renders an abstract themed projection (SVG,
// chosen projection, graticule, optional slotted/inline vector outline) with NO
// tile provider and NO network. Real basemap PIXELS are a keyed exception reached
// through the Host seam (this.host) when configured — never a hard CDN dependency.
//
// Import this barrel to register the domain, or wb-map.js directly to stay lean.
export { WbMap } from "./wb-map.js";
export { project, unproject, bounds } from "./projection.js";
