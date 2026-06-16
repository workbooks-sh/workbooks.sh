// gate · the five gates — node-side static analysis + the parity framework.
//
// The runtime (in-page) halves of gates (a),(b),(e) execute via Playwright in
// run.js; this module owns the pieces that are pure node:
//   • the STATIC half of (a) token-leak — reuses src/validate/design-lint.js
//   • (c) the import-graph scan + the powered-engine seam registry
//   • (d) the functional-parity FRAMEWORK (oracle = floor; no-op until P3)
// plus the shared color helpers the runtime sweep needs for the flip-delta.

import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { lintElementSource } from "../../src/validate/design-lint.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..", "..");

// ── (a) static token-leak — the existing design-lint, per element ─────────────
/**
 * Static CSS lint for ONE element's source. Returns the design-lint errors for
 * that element only (the runtime computed-style sweep + flip-delta run in-page).
 */
export function staticTokenLeak(name, source, contract) {
  return lintElementSource(name, source, contract).filter(
    // the static token gate owns off-token-color / off-system-value / unknown-token;
    // variant-conformance + contrast are design-lint's own CLI scope.
    (e) => ["off-token-color", "off-system-value", "unknown-token"].includes(e.rule),
  );
}

// ── (c) WASM / floor-loadability — static import-graph scan ───────────────────
// Walk an element's module graph (relative imports + bare specifiers) and flag:
//   • a Node built-in imported into a browser element (node:fs, etc.)
//   • a hardcoded CDN import executed AT LOAD (esm.sh/unpkg/jsdelivr/cdn.) — a
//     floor element must not pin a CDN on its load path. (A lazy import() of an
//     engine chunk is the powered seam, handled by the engine-block sub-gate.)
const NODE_BUILTINS = /^(node:|fs$|path$|os$|crypto$|http$|https$|child_process$|stream$|url$|util$)/;
const CDN_RE = /https?:\/\/(esm\.sh|unpkg\.com|cdn\.|jsdelivr\.net|skypack\.dev)/;

export function importGraphScan(entryPath) {
  const seen = new Set();
  const leaks = [];
  const visit = (abs) => {
    if (seen.has(abs) || !existsSync(abs)) return;
    seen.add(abs);
    const src = readFileSync(abs, "utf8");
    // static `import … from "x"` + side-effect `import "x"` (NOT dynamic import())
    const specs = [
      ...src.matchAll(/(?:^|\n)\s*import\s+(?:[^"']*?\s+from\s+)?["']([^"']+)["']/g),
      ...src.matchAll(/(?:^|\n)\s*export\s+(?:\*|\{[^}]*\})\s+from\s+["']([^"']+)["']/g),
    ].map((m) => m[1]);
    for (const spec of specs) {
      if (NODE_BUILTINS.test(spec)) leaks.push({ at: rel(abs), spec, rule: "node-builtin" });
      if (CDN_RE.test(spec)) leaks.push({ at: rel(abs), spec, rule: "load-time-cdn" });
      if (spec.startsWith(".")) {
        const next = resolveRel(abs, spec);
        if (next) visit(next);
      }
    }
  };
  visit(entryPath);
  return leaks;
}
function rel(abs) { return abs.startsWith(ROOT) ? abs.slice(ROOT.length + 1) : abs; }
function resolveRel(fromFile, spec) {
  let p = join(dirname(fromFile), spec);
  if (existsSync(p)) return p;
  if (existsSync(p + ".js")) return p + ".js";
  if (existsSync(join(p, "index.js"))) return join(p, "index.js");
  return null;
}

// ── (c) powered-engine seam registry ──────────────────────────────────────────
// An element gains an entry HERE when P3 swaps a powered engine behind it. The
// gate then asserts the FLOOR still renders with `enginePattern` network-blocked
// (Playwright route-abort). Empty today = every element is pure-floor → gate-c is
// a pass on the static scan alone.
//
//   "work-chart": { enginePattern: /observable|uplot|plot\.js/, floorMustRender: "svg" }
//
export const POWERED_SEAMS = {
  // populated in Phase 3, e.g.:
  // "work-map":    { enginePattern: /maplibre/i,  floorMustRender: ".frame" },
  // "work-editor": { enginePattern: /codemirror/i, floorMustRender: ".frame" },
};

// ── (d) functional-parity FRAMEWORK (oracle = the floor) ──────────────────────
// A powered engine must produce the SAME logical output as the floor it replaces:
// same data series / row set / domain / labels (NOT the same pixels — that's the
// visual gate). The floor IS the oracle. This is a no-op until a powered engine
// registers a fixture below; the framework + plug-in contract ship now.
//
// To plug in at P3: register `{ oracle, candidate, compare }` for the tag.
//   • oracle(page)    → extract the canonical model from the FLOOR render
//                       (e.g. the SVG <rect> count + datum labels for work-chart)
//   • candidate(page) → extract the SAME model from the powered-engine render
//   • compare(a,b)    → { equal, notes } deep-equal of the two models
// run.js mounts the floor, runs oracle; mounts the engine variant, runs candidate.
export const PARITY_FIXTURES = {
  // "work-chart": {
  //   oracle:    async (page) => page.evaluate(() => /* count marks + labels off the floor SVG */),
  //   candidate: async (page) => page.evaluate(() => /* same off the Plot render */),
  //   compare:   (a, b) => ({ equal: JSON.stringify(a) === JSON.stringify(b), notes: "" }),
  // },
};

/**
 * Run the parity gate for a tag. With no registered fixture it is a structural
 * pass (no powered engine to diverge from the floor yet) — documented, honest.
 */
export async function functionalParity(tag, page, mountFloor, mountEngine) {
  const fx = PARITY_FIXTURES[tag];
  if (!fx) return { pass: true, applicable: false, note: "no powered engine — floor is the only impl" };
  await mountFloor();
  const oracle = await fx.oracle(page);
  await mountEngine();
  const candidate = await fx.candidate(page);
  const { equal, notes } = fx.compare(oracle, candidate);
  return { pass: equal, applicable: true, note: notes, oracle, candidate };
}

// ── color helpers (shared with the in-page flip-delta) ────────────────────────
// Parse a computed `rgb(...)`/`rgba(...)` string to a comparable normal form so
// the node side can compute the light-vs-dark delta without re-parsing in-page.
export function normColor(v) {
  if (!v) return null;
  const m = /rgba?\(([^)]+)\)/i.exec(v);
  if (!m) return v.trim();
  const parts = m[1].split(/[,\s/]+/).filter(Boolean).map(Number);
  const [r, g, b] = parts;
  const a = parts[3] != null ? parts[3] : 1;
  if ([r, g, b].some(Number.isNaN)) return v.trim();
  return `${r},${g},${b},${a}`;
}
