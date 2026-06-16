// workponents · git domain — version control without git's vocabulary.
// The user sees only History, Restore, Undo (Draft/Share land alongside). Each
// element registers on import (idempotent); re-exports the classes for typing.
//   <work-diff>           — themed before/after diff, computed in JS (semantic
//                            org-block diff, line-diff fallback). Standalone.
//   <work-history-graph>  — the version timeline (nodes = versions, agent badges,
//                            `selected` event). Standalone (sample/host data).
//   <work-restore>        — append-only restore button. Runtime-wired via this.host.
//   <work-undo>           — undo-last-change button.   Runtime-wired via this.host.
export { WorkDiff } from "./wb-diff.js";
export { WorkHistoryGraph } from "./wb-history-graph.js";
export { WorkRestore } from "./wb-restore.js";
export { WorkUndo } from "./wb-undo.js";
