// workponents · code domain — real in-sandbox eval via the Workbooks compiler
// lane (C/Rust/Zig/Go/JS → wasm); the editor edits composition-as-source live
// (the code IS the artifact's source). Import this barrel to register the whole
// domain, or a single element file to stay lean. Standalone (zero deps): the
// editor is a themed textarea + token highlight; the REPL runs JS in a sandboxed
// worker and shows a graceful "needs runtime" state for compiled languages. The
// editing surface is swap-stable — a CodeMirror 6 engine backs <code-editor>
// (./codemirror-tier.js), lazy-loaded from a CDN behind the same public API; the
// zero-dep textarea+highlight floor is the guaranteed fallback. Lit-based;
// buildless ESM.
export { WorkEditor } from "./work-editor.js";
export { WorkRepl } from "./work-repl.js";
export { runJs } from "./sandbox.js";
export { highlight, highlightLine, normalizeLang, escapeHtml } from "./highlight.js";
export { loadCodeMirror, readEditorTokens, buildTheme, createEditorView } from "./codemirror-tier.js";
