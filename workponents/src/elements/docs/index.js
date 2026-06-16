// workponents · docs domain — the document is its own org/markdown source,
// rendered directly (preview ≡ source), with live computed cells as first-class.
// Tags: <work-doc> · <work-doc-cell> · <work-doc-outline> · <work-doc-import>.
// Self-editing formats: docx ↔ work-doc round-trips via the docx-io adapter
// (mammoth+turndown read · docx write, floor; pandoc.wasm over the Dock for max
// fidelity when docked).
// Import this barrel to register the whole domain, or a single element file to
// stay lean. Standalone (zero deps) by default; full org fidelity + live cell
// compute light up when a Host (kernel/runtime) is reachable via `this.host`.
export { WbDoc } from "./wb-doc.js";
export { WbDocCell } from "./wb-doc-cell.js";
export { WbDocOutline } from "./wb-doc-outline.js";
export { WbDocImport } from "./wb-doc-import.js";
export { renderDoc, parseOutline, escapeHtml } from "./render.js";
export { importDocx, exportDocx, looksLikeDocx } from "./docx-io.js";
export { PROSE_CSS } from "./prose.js";
