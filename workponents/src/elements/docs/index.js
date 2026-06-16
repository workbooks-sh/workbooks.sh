// workponents · docs domain — the document is its own org/markdown source,
// rendered directly (preview ≡ source), with live computed cells as first-class.
// Tags: <work-doc> · <work-doc-cell> · <work-doc-outline>.
// Import this barrel to register the whole domain, or a single element file to
// stay lean. Standalone (zero deps) by default; full org fidelity + live cell
// compute light up when a Host (kernel/runtime) is reachable via `this.host`.
export { WbDoc } from "./wb-doc.js";
export { WbDocCell } from "./wb-doc-cell.js";
export { WbDocOutline } from "./wb-doc-outline.js";
export { renderDoc, parseOutline, escapeHtml } from "./render.js";
export { PROSE_CSS } from "./prose.js";
