// workponents · forms domain — the form IS its schema. A <work-form> owns one
// declarative schema (inline JSON or built from its <work-field> rules) and runs
// the shared `src/validate` layer against the live values — validation is not
// hand-wired per control. Import this barrel to register the whole domain, or a
// single element file to stay lean. Zero-dep sync validation by default; server/
// derived validation lights up when a Host with a /validate route is reachable.
export { WbForm } from "./wb-form.js";
export { WbField } from "./wb-field.js";
export { WbFieldGroup } from "./wb-field-group.js";

// the shared validation layer the forms surface owns (re-exported for convenience;
// records/tables-edit import it directly from ../../validate/).
export { validate, validateRecord, validateRecordAsync, serializeSchema, parseSchema } from "../../validate/index.js";
