// workponents · data — the shared in-WASM data layer for the DuckDB trio.
//
// ONE engine, three surfaces. `tables`, `data-viz`, and `maps` all import from
// here and code against the contract in ./contract.js. Framework-agnostic,
// zero-dependency, token-unaware (pure data — no DOM, no CSS).
//
//   import { getEngine } from "../../data/index.js";
//   const db = getEngine();
//   await db.register("orders", { csv: "...." });        // a workbook's data IS its source
//   const res = await db.query("SELECT region, sum(rev) AS rev FROM orders GROUP BY region");
//   // res = { columns, rows (array-of-array), types, rowCount, engine }
//
// data-viz / maps consume the SAME shape: a chart reads res.rows[i][j] by
// res.columns; a geo-query reads lat/lon columns off the same result. Register
// once, query from every surface on the page (shared connection).
export { getEngine, WbDataEngine } from "./engine.js";
export {
  normalizeSource, parseCsv, coerce, inferType, resultFromObjects,
} from "./contract.js";
export { MemorySql } from "./memory-sql.js";
