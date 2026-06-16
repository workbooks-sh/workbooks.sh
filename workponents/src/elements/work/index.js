// The `work` toolkit — the spine. The irreducible, system-run primitives every
// workbook and toolkit is built from. NOT a visual domain: compute, edges, the DAG.
//   work-src   compute → sandboxed WASM via the Dock
//   work-ref   every edge: pointer · dependency · binding · type (tagging)
// (work-flow lives in ./flow for now; work-button is the loose core UI atom.)
export { WorkSrc } from "./work-src.js";
export { WorkRef } from "./work-ref.js";
