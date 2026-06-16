#!/usr/bin/env node
// workponents · design-lint CLI.
//
// Scans src/elements/** for `static styles` token leaks + off-system values +
// unknown tokens + variant conformance, and lints every registered theme for
// WCAG contrast. Reads theme-contract.json (the single source) and registry.js
// (resolved theme colors). Exit 1 on any error. `node tools/design-lint.mjs`
// (or `npm run lint:design`).

import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";
import { designLint } from "../src/validate/design-lint.js";
import { resolveTokens, listThemes } from "../src/theme/registry.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");

const contract = JSON.parse(readFileSync(join(ROOT, "theme-contract.json"), "utf8"));

// Collect every .js under src/elements/, deriving the registered tag name from
// its define("work-…", …) call (an element file may register several tags; lint
// each declared name against the same source).
function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (p.endsWith(".js")) out.push(p);
  }
  return out;
}

const files = walk(join(ROOT, "src", "elements"));
const elements = [];
for (const file of files) {
  const source = readFileSync(file, "utf8");
  const names = [...source.matchAll(/define\(\s*["'](work-[a-z0-9-]+)["']/g)].map((m) => m[1]);
  // Fall back to a path-derived name so files with no define() still get linted.
  const tags = names.length ? names : [relative(join(ROOT, "src", "elements"), file).replace(/\.js$/, "")];
  for (const name of tags) elements.push({ name, source, file });
}

const { valid, errors } = designLint(elements, contract, resolveTokens);

const byRule = {};
for (const e of errors) (byRule[e.rule] ||= []).push(e);

console.log(`design-lint — ${elements.length} element decls, ${listThemes().length} themes\n`);
if (valid) {
  console.log("PASS — no design-system violations.");
  process.exit(0);
}
for (const [rule, list] of Object.entries(byRule)) {
  console.log(`  [${rule}] ${list.length}`);
  for (const e of list) console.log(`    ${e.path}: ${e.message}`);
  console.log("");
}
console.log(`FAIL — ${errors.length} violation(s).`);
process.exit(1);
