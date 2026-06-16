// workponents · pm domain — the project-management structural vocabulary.
// These are CONFIG-ISLAND elements: the org-mode PM ideas (TODO/DONE state, tags,
// SCHEDULED/DEADLINE dates, properties, outline nesting) re-expressed as plain
// attributes on themed <work-*> custom elements. The HTML IS the source; each
// element renders its own attributes (status pills, assignee chips, due/estimate),
// never post-hoc regex chrome. Composition-as-source throughout: a board's columns,
// a sprint's backlog, are its slotted <board-task> children.
//
// Time is host-injected — these elements present the date/duration strings they are
// authored with and do pure presentation; "now" is always a parameter the host
// supplies, never a clock read (see docs/WORK-FORMAT.md).
//
// Importing this barrel registers the elements (idempotent via define()) and
// re-exports the classes. Lit-based; buildless ESM.
//
//   import "workponents/src/elements/pm/index.js"; // register + use the tags
//   import { WorkTask } from ".../pm/index.js";     // the class
export { WorkTask } from "./work-task.js";
export { WorkBoard } from "./work-board.js";
export { WorkSprint } from "./work-sprint.js";
export { WorkMilestone } from "./work-milestone.js";
