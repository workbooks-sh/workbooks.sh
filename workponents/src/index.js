// workponents — register every element + re-export the classes.
// Import this for the whole set, or import a single element from ./elements/<name>.js
// to keep a workbook lean. Theme via ./theme/tokens.css.
export { WbElement, html, css, define } from "./core/element.js";
export { WbHost, configureHost, getHost } from "./core/host.js";
export { defineVariants, resolveVariant, variantAttrs, lintVariants } from "./core/variants.js";

// base element (the reference)
export { WbButton } from "./elements/work-button.js";

// domains — importing a barrel registers its elements (idempotent) + re-exports
// the classes. Import the whole set here, or a single ./elements/<domain>/index.js
// (or one file) to keep a workbook lean.
export * from "./elements/ai/index.js";       // work-thread, work-message, work-gen-block, work-composer
export * from "./elements/docs/index.js";     // work-doc, work-doc-cell, work-doc-outline
export * from "./elements/git/index.js";      // work-diff, work-history-graph, work-restore, work-undo
export * from "./elements/video/index.js";    // work-video, work-video-source
export * from "./elements/tables/index.js";   // work-table, work-column
export * from "./elements/data-viz/index.js"; // work-chart, work-spark, work-metric
export * from "./elements/maps/index.js";     // work-map
export * from "./elements/forms/index.js";    // work-form, work-field, work-field-group (+ the src/validate layer)
export * from "./elements/records/index.js";  // work-record, work-record-list, work-field-value
export * from "./elements/search/index.js";   // work-search, work-command
export * from "./elements/auth/index.js";     // work-auth, work-user, work-gate (+ the identity seam)
export * from "./elements/presentation/index.js"; // work-deck, work-slide
export * from "./elements/code/index.js";     // work-editor, work-repl
export * from "./elements/files/index.js";    // work-drive, work-file, work-dropzone
export * from "./elements/live/index.js";     // work-room, work-presence, work-live-value

// shared SQLite data layer (runtime VFS / in-page sqlite-wasm / memory floor,
// behind the Host seam) — the one engine the data surfaces query.
export { getEngine } from "./data/index.js";
