// workponents · data-viz domain — a chart IS a view over a query. Aggregation /
// binning / grouping run IN the shared engine (DuckDB on the runtime tier ·
// browser duckdb-wasm · the in-JS subset offline); the element issues SQL and
// renders the result as zero-dependency, token-themed SVG. The chart-vs-data gap
// dissolves — it is a live query you can talk to. Reach compute only through
// ../../data (one engine, three surfaces: tables / data-viz / maps). Re-based onto
// the Lit FLOOR.
//
// Import this barrel to register the domain, or a single element file to stay
// lean. Standalone (zero deps, no build) by default; the runtime DuckDB tier
// lights up when a Host is reachable via `this.host`.
export { WbChart } from "./wb-chart.js";
export { WbSpark } from "./wb-spark.js";
export { WbMetric } from "./wb-metric.js";
