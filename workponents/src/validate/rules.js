// workponents · validate — the shared, declarative validation layer.
//
// The cross-cutting Validation pillar. Zero-dependency, framework- AND
// token-unaware (pure logic): no DOM, no CSS, no custom-element coupling. The
// `forms` surface consumes it now; `records` / `tables-edit` reuse the SAME
// contract + result shape later — so validation is authored once, as source,
// not hand-wired per field.
//
// ── The rule contract ──────────────────────────────────────────────────────
// A field rule is a plain object (declarative source — serializable to/from
// JSON, agent-editable). Recognized keys:
//
//   { type:     "string"|"number"|"integer"|"boolean"|"email"|"url"|"date",
//     required: true,                 // non-empty / present
//     min, max:  Number,              // number range, OR string/array length
//     minLength, maxLength: Number,   // explicit length (alias of min/max for strings)
//     pattern:  RegExp | string,      // string must match (string = RegExp source)
//     enum:     [..allowed values..], // value must be one of these
//     equals:   <ref>,                // cross-field: must equal sibling field <ref>
//     custom:   (value, ctx) => true | "message",  // arbitrary predicate
//     message:  "override message",   // single message for any failure on this field
//     label:    "Email address",      // human label used in default messages
//   }
//
// A SCHEMA maps field path → rule:  { email: {type:"email", required:true}, ... }
//
// ── The result shape (uniform, every surface returns this) ──────────────────
//   { valid: Boolean, errors: [ { path, rule, message } ] }
// where `path` is the field key (dotted for nested), `rule` is the failing rule
// key (e.g. "required" | "pattern" | "equals" | "custom"), `message` is human.
// `validate(value, rule)` returns the same shape with path = "" (single field).
//
// ── Sync floor + Host hook ──────────────────────────────────────────────────
// Everything here is the SYNCHRONOUS in-JS floor — runs offline, no engine.
// Server/derived validation (uniqueness, cross-record constraints) layers on top
// via `validateRecordAsync(obj, schema, host)`, which runs the sync floor first,
// then — only if a `host` with a reachable `/validate` route is given — merges
// server errors. The floor is authoritative for everything it can decide; the
// Host only ADDS errors it alone can know. Elements degrade cleanly with no host.

/** RFC-pragmatic email + url checks (deliberately permissive, not RFC-perfect). */
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const URL_RE = /^https?:\/\/[^\s.]+\.[^\s]+$/i;

function isEmpty(v) {
  return v == null || v === "" || (Array.isArray(v) && v.length === 0);
}

/** Coerce a raw value (DOM strings, etc.) by declared type for checks. */
function coerce(v, type) {
  if (v == null) return v;
  if (type === "number" || type === "integer") {
    if (typeof v === "number") return v;
    const s = String(v).trim();
    if (s === "") return NaN;
    return Number(s);
  }
  if (type === "boolean") {
    if (typeof v === "boolean") return v;
    return v === "true" || v === "on" || v === "1" || v === true;
  }
  return v;
}

function typeError(value, type) {
  switch (type) {
    case "number":
      return Number.isNaN(value) || typeof value !== "number" ? "must be a number" : null;
    case "integer":
      return Number.isNaN(value) || !Number.isInteger(value) ? "must be a whole number" : null;
    case "boolean":
      return typeof value !== "boolean" ? "must be true or false" : null;
    case "email":
      return EMAIL_RE.test(String(value)) ? null : "must be a valid email";
    case "url":
      return URL_RE.test(String(value)) ? null : "must be a valid URL";
    case "date": {
      const t = Date.parse(String(value));
      return Number.isNaN(t) ? "must be a valid date" : null;
    }
    case "string":
    default:
      return null;
  }
}

function label(rule) {
  return rule && rule.label ? rule.label : "This field";
}

/**
 * Validate ONE value against ONE rule. Synchronous, pure.
 * @param {*} value raw value
 * @param {object} rule the declarative rule
 * @param {object} [ctx] sibling values for cross-field rules ({ record, path })
 * @returns {{valid:boolean, errors:{path:string,rule:string,message:string}[]}}
 */
export function validate(value, rule, ctx = {}) {
  const errors = [];
  const path = ctx.path || "";
  const push = (rk, msg) => errors.push({ path, rule: rk, message: rule.message || msg });

  if (!rule || typeof rule !== "object") return { valid: true, errors };

  // required — short-circuits the rest if unmet (nothing else to check).
  // For a boolean field (a consent checkbox) "required" means it must be TRUE,
  // not merely present, so an unchecked box fails.
  const reqUnmet = rule.type === "boolean"
    ? coerce(value, "boolean") !== true
    : isEmpty(value);
  if (reqUnmet) {
    if (rule.required) push("required", `${label(rule)} is required.`);
    return { valid: errors.length === 0, errors };
  }

  const type = rule.type || "string";
  const v = coerce(value, type);

  // type
  const te = typeError(v, type);
  if (te) push("type", `${label(rule)} ${te}.`);

  // numeric range / length
  const isNum = type === "number" || type === "integer";
  if (rule.min != null) {
    if (isNum) { if (v < rule.min) push("min", `${label(rule)} must be at least ${rule.min}.`); }
    else { const len = String(value).length; if (len < rule.min) push("min", `${label(rule)} must be at least ${rule.min} characters.`); }
  }
  if (rule.max != null) {
    if (isNum) { if (v > rule.max) push("max", `${label(rule)} must be at most ${rule.max}.`); }
    else { const len = String(value).length; if (len > rule.max) push("max", `${label(rule)} must be at most ${rule.max} characters.`); }
  }
  if (rule.minLength != null && String(value).length < rule.minLength) push("minLength", `${label(rule)} must be at least ${rule.minLength} characters.`);
  if (rule.maxLength != null && String(value).length > rule.maxLength) push("maxLength", `${label(rule)} must be at most ${rule.maxLength} characters.`);

  // pattern
  if (rule.pattern != null) {
    const re = rule.pattern instanceof RegExp ? rule.pattern : new RegExp(rule.pattern);
    if (!re.test(String(value))) push("pattern", `${label(rule)} is not in the expected format.`);
  }

  // enum
  if (Array.isArray(rule.enum) && !rule.enum.includes(value)) {
    push("enum", `${label(rule)} must be one of: ${rule.enum.join(", ")}.`);
  }

  // cross-field equality (ctx.record carries siblings)
  if (rule.equals != null && ctx.record && ctx.record[rule.equals] !== value) {
    push("equals", `${label(rule)} must match ${rule.equals}.`);
  }

  // custom predicate — true | undefined = ok; string | false = fail (string = msg)
  if (typeof rule.custom === "function") {
    const r = rule.custom(value, ctx);
    if (r === false) push("custom", `${label(rule)} is invalid.`);
    else if (typeof r === "string") push("custom", r);
  }

  return { valid: errors.length === 0, errors };
}

/**
 * Validate a whole record against a schema. Synchronous, pure. Every field's
 * errors carry its `path`. Sibling values are passed as ctx.record so cross-field
 * rules (equals, custom) can see the rest of the record.
 * @param {object} obj the record { path: value }
 * @param {object} schema { path: rule }
 * @returns {{valid:boolean, errors:{path:string,rule:string,message:string}[]}}
 */
export function validateRecord(obj, schema) {
  const errors = [];
  obj = obj || {};
  for (const [path, rule] of Object.entries(schema || {})) {
    const { errors: fe } = validate(obj[path], rule, { record: obj, path });
    for (const e of fe) errors.push(e);
  }
  return { valid: errors.length === 0, errors };
}

/**
 * Async record validation: the sync floor, then optional server/derived merge.
 * The floor is authoritative for everything it decides; a reachable Host only
 * ADDS errors it alone can know (uniqueness, cross-record). Degrades to the floor
 * when no host / route is reachable. Endpoint contract: POST /validate
 *   → { errors: [{path, rule, message}] }  (empty = server-clean)
 * @param {object} obj
 * @param {object} schema
 * @param {object} [host] a WbHost (this.host) — optional
 * @returns {Promise<{valid:boolean, errors:{path,rule,message}[], live:boolean}>}
 */
export async function validateRecordAsync(obj, schema, host) {
  const local = validateRecord(obj, schema);
  // Only consult the server when the floor passed (don't double-report) AND a
  // host with a /validate capability is reachable.
  if (!local.valid || !host || typeof host.available !== "function" || !host.available("validate")) {
    return { ...local, live: false };
  }
  try {
    const res = await host.request("/validate", { body: { values: obj, schema: serializeSchema(schema) } });
    const serverErrors = (res && Array.isArray(res.errors)) ? res.errors : [];
    const errors = [...local.errors, ...serverErrors];
    return { valid: errors.length === 0, errors, live: true };
  } catch {
    return { ...local, live: false };
  }
}

/**
 * Serialize a schema to JSON-safe source (RegExp → {source, flags}, functions
 * dropped — server can't run them). Lets a schema cross the Host seam / be stored
 * as composition-as-source. `parseSchema` is the inverse for the JS side.
 */
export function serializeSchema(schema) {
  const out = {};
  for (const [k, rule] of Object.entries(schema || {})) {
    const r = { ...rule };
    if (r.pattern instanceof RegExp) r.pattern = { source: r.pattern.source, flags: r.pattern.flags };
    delete r.custom; // not serializable; sync-only
    out[k] = r;
  }
  return out;
}

/** Inverse of serializeSchema for the JS floor ({source,flags} → RegExp). */
export function parseSchema(json) {
  const out = {};
  for (const [k, rule] of Object.entries(json || {})) {
    const r = { ...rule };
    if (r.pattern && typeof r.pattern === "object" && "source" in r.pattern) {
      r.pattern = new RegExp(r.pattern.source, r.pattern.flags || "");
    }
    out[k] = r;
  }
  return out;
}
