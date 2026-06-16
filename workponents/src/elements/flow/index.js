// workponents · flow domain — the agentic structural vocabulary: flows (sequenced
// pipelines of steps with visible in/out/deps build edges) and loops (recurring
// cron jobs with a run status). Config-island elements, peers to the existing
// work-agent / work-system structural elements; the HTML IS the source and each
// element renders its own attributes (no JSON IR, no regex chrome).
//
// Time is host-injected — these elements present their cadence/edge strings and do
// pure presentation; computing fire-times and triggering is the host's job, never a
// clock read here (see docs/WORK-FORMAT.md).
//
// Importing this barrel registers the elements (idempotent via define()) and
// re-exports the classes. Lit-based; buildless ESM.
//
//   import "workponents/src/elements/flow/index.js"; // register + use the tags
//   import { WorkFlow } from ".../flow/index.js";     // the class
export { WorkFlow } from "./work-flow.js";
export { WorkLoop } from "./work-loop.js";
