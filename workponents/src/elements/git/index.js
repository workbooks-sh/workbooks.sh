// workponents · git domain — version control without git's vocabulary.
// The user sees only History, Restore, Undo (Draft/Share land alongside). Each
// element registers on import (idempotent); re-exports the classes for typing.
//   <wb-diff>           — themed before/after diff, computed in JS (semantic
//                          org-block diff, line-diff fallback). Standalone.
//   <wb-history-graph>  — the version timeline (nodes = versions, agent badges,
//                          `selected` event). Standalone (sample/host data).
//   <wb-restore>        — append-only restore button. Runtime-wired via this.host.
//   <wb-undo>           — undo-last-change button.   Runtime-wired via this.host.
export { WbDiff } from "./wb-diff.js";
export { WbHistoryGraph } from "./wb-history-graph.js";
export { WbRestore } from "./wb-restore.js";
export { WbUndo } from "./wb-undo.js";
