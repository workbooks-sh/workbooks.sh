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
export * from "./elements/ai/index.js";       // chat-thread, chat-message, chat-gen-block, chat-composer
export * from "./elements/docs/index.js";     // document-view, document-cell, document-outline
export * from "./elements/git/index.js";      // git-diff, git-history-graph, git-restore, git-undo
export * from "./elements/video/index.js";    // video-player, video-source
export * from "./elements/tables/index.js";   // grid-table, grid-column
export * from "./elements/data-viz/index.js"; // chart-view, chart-spark, chart-metric
export * from "./elements/maps/index.js";     // map-view
export * from "./elements/forms/index.js";    // form-view, form-field, form-field-group (+ the src/validate layer)
export * from "./elements/records/index.js";  // record-view, record-list, record-field-value
export * from "./elements/search/index.js";   // search-box, search-command
export * from "./elements/auth/index.js";     // auth-panel, auth-user, auth-gate (+ the identity seam)
export * from "./elements/presentation/index.js"; // deck-view, deck-slide
export * from "./elements/code/index.js";     // code-editor, code-repl
export * from "./elements/files/index.js";    // file-drive, file-card, file-dropzone
export * from "./elements/live/index.js";     // live-room, live-presence, live-value
export * from "./elements/3d/index.js";        // model-view, model-source
export * from "./elements/pm/index.js";        // board-task, board-view, board-sprint, board-milestone
export * from "./elements/flow/index.js";      // work-flow, work-loop
export * from "./elements/data/index.js";      // data-query (named source; views bind via from=)
export * from "./elements/work/index.js";      // work-src, work-ref (the spine)

// shared SQLite data layer (runtime VFS / in-page sqlite-wasm / memory floor,
// behind the Host seam) — the one engine the data surfaces query.
export { getEngine } from "./data/index.js";
