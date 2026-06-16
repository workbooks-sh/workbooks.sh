#!/usr/bin/env node
// cem.mjs — emit the Custom Elements Manifest (custom-elements.json) for workponents.
//
// Zero extra deps: a source scan (regex, not a real JS parser) over
// src/elements/**, the only floor we need. For each registered `work-*` tag it
// records:
//   • attributes — from `static props = [...]` (string literals + a spread of
//     `variantAttrs(VARIANTS)` resolved from the file's `defineVariants({...})`),
//   • events     — best-effort from `this._emit("…")` and
//                  `dispatchEvent(new CustomEvent("…"))` call sites,
//   • domain     — the subdirectory under src/elements/ (ai/git/tables/…), which
//     is the per-domain component toolkit it belongs to,
//   • class/module — for tooling/import resolution.
//
// This is the machine-readable catalog the agent component-discovery, the
// theme-contract, and the evals all consume. It is intentionally a static
// catalog (no runtime registration), so it runs in CI with `node` alone.
//
// Output schema follows the Custom Elements Manifest v1 shape
// (https://github.com/webcomponents/custom-elements-manifest) closely enough for
// consumers + VS Code html.customData, with a workponents `domain` extension.

import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname, relative, basename } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const ELEMENTS = join(ROOT, "src", "elements");
const OUT = join(ROOT, "custom-elements.json");

// ── source walk ────────────────────────────────────────────────────────────
function jsFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...jsFiles(p));
    else if (name.endsWith(".js")) out.push(p);
  }
  return out;
}

// The directory under src/elements/ is the domain (the per-domain component
// toolkit). Files directly in src/elements/ (e.g. work-button.js) are "core".
function domainOf(file) {
  const rel = relative(ELEMENTS, file);
  const seg = rel.split("/");
  return seg.length > 1 ? seg[0] : "core";
}

// ── per-file extraction ──────────────────────────────────────────────────────
const reDefine = /\bdefine\(\s*["']([\w-]+)["']\s*,\s*([A-Za-z_$][\w$]*)\s*\)/g;
const reProps = /static\s+props\s*=\s*\[([\s\S]*?)\]/;
const reStringLit = /["']([\w-]+)["']/g;
const reVariants = /(\b[A-Za-z_$][\w$]*)\s*=\s*defineVariants\(\s*\{([\s\S]*?)\}\s*\)/;
const reEmit = /\bthis\._emit\(\s*["']([\w-]+)["']/g;
const reDispatch = /dispatchEvent\(\s*new\s+(?:Custom)?Event\(\s*["']([\w-]+)["']/g;

// Top-level keys of a defineVariants({...}) object literal — these are the
// reflected variant attribute names (variant/size/tone/…). Depth-aware so nested
// option arrays/objects don't leak their keys.
function variantKeys(body) {
  const keys = [];
  let depth = 0;
  let i = 0;
  const n = body.length;
  while (i < n) {
    const c = body[i];
    if (c === "{" || c === "[" || c === "(") depth++;
    else if (c === "}" || c === "]" || c === ")") depth--;
    else if (depth === 0) {
      const m = /^([A-Za-z_$][\w$]*)\s*:/.exec(body.slice(i));
      if (m) {
        keys.push(m[1]);
        i += m[0].length;
        continue;
      }
    }
    i++;
  }
  return keys;
}

function attributesFor(src, classBody) {
  const pm = reProps.exec(classBody);
  if (!pm) return [];
  const inner = pm[1];
  const attrs = [];

  // explicit string-literal attrs
  let m;
  reStringLit.lastIndex = 0;
  while ((m = reStringLit.exec(inner))) attrs.push(m[1]);

  // spread of variantAttrs(VARIANTS) → resolve the local defineVariants object
  if (/\.\.\.\s*variantAttrs\(/.test(inner)) {
    const vm = reVariants.exec(src);
    if (vm) attrs.unshift(...variantKeys(vm[2]));
  }
  return [...new Set(attrs)];
}

function eventsFor(classBody) {
  const evts = new Set();
  let m;
  reEmit.lastIndex = 0;
  while ((m = reEmit.exec(classBody))) evts.add(m[1]);
  reDispatch.lastIndex = 0;
  while ((m = reDispatch.exec(classBody))) evts.add(m[1]);
  return [...evts];
}

// ── build the manifest ───────────────────────────────────────────────────────
const modules = [];
let tagCount = 0;

for (const file of jsFiles(ELEMENTS).sort()) {
  const src = readFileSync(file, "utf8");
  reDefine.lastIndex = 0;
  const defs = [...src.matchAll(reDefine)];
  if (defs.length === 0) continue;

  const domain = domainOf(file);
  const path = relative(ROOT, file);
  const declarations = [];

  for (const [, tagName, className] of defs) {
    tagCount++;
    declarations.push({
      kind: "class",
      customElement: true,
      tagName,
      name: className,
      domain,
      attributes: attributesFor(src, src).map((name) => ({ name })),
      events: eventsFor(src).map((name) => ({ name })),
    });
  }

  modules.push({
    kind: "javascript-module",
    path,
    declarations,
    exports: declarations.map((d) => ({
      kind: "custom-element-definition",
      name: d.tagName,
      declaration: { name: d.name, module: path },
    })),
  });
}

const manifest = {
  schemaVersion: "1.0.0",
  readme: "workponents — Workbooks web-component SDK. Generated by tools/cem.mjs (npm run cem). Each declaration carries a workponents `domain` (the per-domain component toolkit it belongs to).",
  modules: modules.sort((a, b) => a.path.localeCompare(b.path)),
};

writeFileSync(OUT, JSON.stringify(manifest, null, 2) + "\n");

const byDomain = {};
for (const mod of modules) for (const d of mod.declarations) byDomain[d.domain] = (byDomain[d.domain] || 0) + 1;
console.error(`cem: ${tagCount} work-* tags across ${Object.keys(byDomain).length} domains → ${relative(ROOT, OUT)}`);
console.error("  " + Object.entries(byDomain).map(([k, v]) => `${k}:${v}`).join("  "));
