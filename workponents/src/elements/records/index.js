// workponents · records domain — a record IS a row. The detail view of one
// entity (record-view), a master card index over a query (record-list), and the
// typed single-value atom both reuse (record-field-value). Built on the SAME shared
// in-WASM data layer as tables / data-viz / maps (../../data: runtime DuckDB ·
// browser duckdb-wasm · in-JS offline floor) — never a second data store; a
// record view is just a query over the one engine. Editing writes back through
// the Host/Dock seam (this.host → /data/update), degrading read-only with no Host.
//
// Import this barrel to register the domain, or a single element file to stay
// lean. Standalone (zero deps, no build) by default.
export { WbFieldValue } from "./wb-field-value.js";
export { WbRecord } from "./wb-record.js";
export { WbRecordList } from "./wb-record-list.js";
