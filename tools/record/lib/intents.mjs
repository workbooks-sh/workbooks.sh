// The one intent seam. A recipe step is a driver-agnostic intent; a backend
// fulfills it. Canon: guest emits intents, a trusted executor (MCP host /
// Playwright) performs them and returns pixels/DOM. Same shape both backends.
//
// Intent kinds (the seam):
//   navigate { url }            web-only; MCP backend ignores (app drives itself)
//   click    { selector | x,y } resolve + synthetic click
//   type     { selector?, text, perKeyMs? }  realistic typing
//   hover    { selector }
//   wait     { ms } | { selector, timeoutMs }
//   screenshot { name? }        -> returns { path } (PNG)
//   eval_js  { code }           -> returns { value }
//   dom_read { selector? }      -> returns { html }
//
// A backend implements `perform(intent, ctx)` and `screenshot(name)`. Every
// backend MUST honor the same intent kinds so a recipe is portable across them.

export const INTENT_KINDS = new Set([
  "navigate",
  "click",
  "type",
  "hover",
  "wait",
  "screenshot",
  "eval_js",
  "dom_read",
]);

export function validateStep(step, i) {
  if (!step || typeof step !== "object") throw new Error(`step ${i}: not an object`);
  if (!INTENT_KINDS.has(step.intent)) {
    throw new Error(`step ${i}: unknown intent "${step.intent}" (have: ${[...INTENT_KINDS].join(", ")})`);
  }
  if (step.intent === "click" && !step.selector && !(typeof step.x === "number")) {
    throw new Error(`step ${i}: click needs a selector or x,y`);
  }
  if (step.intent === "type" && typeof step.text !== "string") {
    throw new Error(`step ${i}: type needs text`);
  }
  // navigate: web backend uses `url`; app/MCP backend uses `workbook` (open by path)
  if (step.intent === "navigate" && !step.url && !step.workbook)
    throw new Error(`step ${i}: navigate needs url (web) or workbook (app)`);
  if (step.intent === "eval_js" && !step.code) throw new Error(`step ${i}: eval_js needs code`);
  return true;
}

// Human-ish keystroke delay: Gaussian jitter around a base (Box–Muller).
export function gaussianDelay(baseMs = 90, sigma = 35) {
  const u1 = Math.random() || 1e-9;
  const u2 = Math.random();
  const z = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
  return Math.max(12, Math.round(baseMs + z * sigma));
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
