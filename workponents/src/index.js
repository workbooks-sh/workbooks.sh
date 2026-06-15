// workponents — register every element + re-export the classes.
// Import this for the whole set, or import a single element from ./elements/<name>.js
// to keep a workbook lean. Theme via ./theme/tokens.css.
export { WbElement, define } from "./core/element.js";
export { WbHost, configureHost, getHost } from "./core/host.js";
export { defineVariants, resolveVariant, variantAttrs, lintVariants } from "./core/variants.js";

// base element
export { WbButton } from "./elements/wb-button.js";

// domains — importing a barrel registers its elements (idempotent) + re-exports
// the classes. Import the whole set here, or a single ./elements/<domain>/index.js
// (or one file) to keep a workbook lean.
export * from "./elements/ai/index.js";       // wb-thread, wb-message, wb-gen-block, wb-composer
export * from "./elements/docs/index.js";     // wb-doc, wb-doc-cell, wb-doc-outline
export * from "./elements/git/index.js";      // wb-diff, wb-history-graph, wb-restore, wb-undo
export * from "./elements/video/index.js";    // wb-video, wb-video-source
export * from "./elements/tables/index.js";   // wb-table, wb-column

// shared in-WASM data layer (DuckDB-wasm / memory floor, behind the Host seam) —
// the one engine the DuckDB trio (tables/data-viz/maps) queries.
export { getEngine } from "./data/index.js";
