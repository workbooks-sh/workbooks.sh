// workponents · search domain — search IS a query. An instant search box and a
// ⌘K command palette over the ONE shared engine (runtime DuckDB · browser
// duckdb-wasm · in-JS offline floor) — never a JS .filter() over a preloaded
// array. Each keystroke runs a debounced engine query (WHERE … LIKE); the command
// palette adds an in-WASM fuzzy ranking (./rank.js) for ordered relevance over a
// command set the SQL LIKE can't express. Reach compute only through ../../data.
//
// Import this barrel to register the domain, or a single element file to stay
// lean. Zero-dep authoring contract; Lit is a buildless peer dep (import map in
// demos). The runtime DuckDB tier lights up via `this.host`.
export { WorkSearch } from "./work-search.js";
export { WorkCommand } from "./work-command.js";
export { fuzzyScore, rank, highlight } from "./rank.js";
