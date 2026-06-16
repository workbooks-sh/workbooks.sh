// workponents · tables domain — the table IS a query. A thin, virtualized
// viewport over a WbQueryResult; sort / filter / aggregate run IN the shared
// DuckDB engine (runtime tier · browser duckdb-wasm · in-JS offline floor),
// never in the element. Reach compute only through ../../data (one engine, three
// surfaces: tables / data-viz / maps). Re-based onto the Lit FLOOR.
//
// Import this barrel to register the domain, or a single element file to stay
// lean. Standalone (zero deps, no build) by default; the runtime DuckDB tier
// lights up when a Host is reachable via `this.host`.
export { WbTable } from "./wb-table.js";
export { WbColumn } from "./wb-column.js";
