// workponents · validate — barrel for the shared validation layer.
//
// The cross-cutting Validation pillar (a form/record IS its schema; validation
// runs against a declarative rule contract, not hand-wired per field). Zero-dep,
// framework- and token-unaware pure logic. Consumed by `forms` now; `records` /
// `tables-edit` reuse the same contract + result shape later.
//
//   import { validate, validateRecord } from "../../validate/index.js";
//
// Contract & result shape are documented in ./rules.js (read that for the full
// rule grammar). The uniform result everywhere: { valid, errors:[{path,rule,message}] }.
export {
  validate,
  validateRecord,
  validateRecordAsync,
  serializeSchema,
  parseSchema,
} from "./rules.js";
