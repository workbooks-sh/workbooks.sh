// workponents · data domain — declarative data SOURCES in the document. A
// <data-query> declares a named, queryable dataset; view elements (grid-table /
// chart-view / record-list) read it via from="<name>". One source element +
// a from= binding — no per-database tags; the SAME tag answers over SQLite or
// Postgres because the Host decides where the query runs (see docs/WORK-FORMAT.md).
//
// This is the structural data vocabulary; the SHARED query engine it routes through
// lives in ../../data (runtime VFS / in-page sqlite-wasm / in-JS floor, behind the
// Dock seam) — the same one engine the view surfaces query.
//
// Importing this barrel registers the element (idempotent via define()) and
// re-exports the class. Lit-based; buildless ESM.
export { WorkQuery } from "./work-query.js";
