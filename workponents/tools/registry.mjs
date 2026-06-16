#!/usr/bin/env node
// registry.mjs — emit the shadcn-style copy-in registry for workponents
// (`registry/**`). The distribution surface: a consumer copies a themed
// `<work-*>` element AND its transitive dependency set (core + data/validate +
// tier files + the token contract) into their own project.
//
// Zero extra deps (the cem.mjs floor): a static source scan over src/**.
//   • files        — transitive closure of the element's RELATIVE imports
//     (../core/*, ../../data/*, tier files, the domain barrel — resolved by
//     walking `import … from "…"` and `export … from "…"`), each as a
//     {path, content, target} copy-in record.
//   • dependencies — npm packages the file set imports as BARE specifiers
//     (`lit`, `lit/directives/*`) → the install-time deps.
//   • peerDependencies — the OPTIONAL CDN tiers a tier file lazy-import()s at
//     runtime (Observable Plot, MapLibre, CodeMirror, MiniSearch). Not installed
//     to copy in the element; light up the heavy engine when reachable.
//   • registryDependencies — other registry items this one pulls (always the
//     `theme` item; `data` when a data surface; `validate` when a form surface) —
//     the shadcn cross-item edge.
//   • tokens       — the `var(--work-*)` custom properties referenced across the
//     file set (the slice of the theme contract this element consumes).
//   • attributes/events/domain — from custom-elements.json (the CEM).
//
// This is the artifact-side mirror of the toolkit `#+REQUIRES` graph: the
// runtime computes a transitive REQUIRES closure at subscription time; this
// computes the same closure statically and materializes it as copy-in files.
// One dependency idea, two distribution surfaces.
//
// Output schema follows the shadcn registry-item shape (name / type / files /
// dependencies / registryDependencies / cssVars) with a workponents `domain`
// + `tokens` + `peerDependencies` extension. Runs in CI with `node` alone.
//
//   npm run registry

import {
  readFileSync, writeFileSync, readdirSync, statSync, mkdirSync, rmSync, existsSync,
} from "node:fs";
import { join, dirname, relative, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(ROOT, "src");
const CEM_PATH = join(ROOT, "custom-elements.json");
const OUT = join(ROOT, "registry");
const SCHEMA = "https://workbooks.sh/schema/registry-item.json";

// ── domain taglines (the 13 element domains + the base) ──────────────────────
// One line each — the index groups by these. Derived from manifest.org / the
// per-domain barrel headers; kept terse so the index reads as a catalog.
const DOMAIN_TAGLINES = {
  core: "The base element + variant contract + the reference work-button.",
  ai: "Conversational surfaces — thread, message, generative block, composer.",
  auth: "Identity & access — sign-in, the current user, capability gates.",
  code: "Code surfaces — a themed editor and a sandboxed REPL.",
  "data-viz": "A chart is a live view over a query — chart, spark, metric.",
  docs: "Prose & document structure — doc, doc-cell, outline.",
  files: "File surfaces — a drive, a file card, a dropzone.",
  forms: "Schema-driven forms — form, field, field-group (over src/validate).",
  git: "Version surfaces — diff, history graph, restore, undo.",
  live: "Realtime presence — room, presence, live value.",
  maps: "Geospatial — a map as a view over a spatial query.",
  pm: "Project management — task, board, sprint, milestone.",
  flow: "Agentic structure — flow (sequenced steps + build edges) and loop (cron jobs).",
  presentation: "Slide decks — deck and slide.",
  records: "Structured records — record, record-list, field-value.",
  search: "Search & command — search box, command palette, command item.",
  tables: "Tabular data over the shared engine — table and column.",
  video: "Video surfaces — video and video-source.",
};

// ── source walk ──────────────────────────────────────────────────────────────
function read(p) { return readFileSync(p, "utf8"); }

// Collect every `… from "<spec>"` specifier (static import AND re-export) plus
// static `import "<spec>"` side-effect forms. (Dynamic import() is handled
// separately as the optional CDN peer tier — those are intentionally NOT copied.)
//
// The keyword must start a STATEMENT (line boundary, allowing leading
// whitespace) — this avoids false hits on the strings "import"/"export"/"from"
// that appear inside quoted arrays (e.g. a JS-keyword list in a highlighter).
const FROM_RE = /(?:^|\n)\s*(?:import|export)\b(?:(?!\n\s*(?:import|export)\b)[\s\S])*?\bfrom\s*["']([^"']+)["']/g;
const SIDE_RE = /(?:^|\n)\s*import\s*["']([^"']+)["']/g;
function specifiers(code) {
  const out = new Set();
  let m;
  while ((m = FROM_RE.exec(code))) out.add(m[1]);
  while ((m = SIDE_RE.exec(code))) out.add(m[1]);
  return [...out];
}

const isRelative = (s) => s.startsWith("./") || s.startsWith("../");
const isLit = (s) => s === "lit" || s.startsWith("lit/");

// Resolve a relative specifier from a file to an absolute src/ path.
function resolveLocal(fromFile, spec) {
  let p = resolvePath(dirname(fromFile), spec);
  if (existsSync(p) && statSync(p).isFile()) return p;
  if (existsSync(p + ".js")) return p + ".js";
  if (existsSync(join(p, "index.js"))) return join(p, "index.js");
  return null;
}

// Transitive closure of LOCAL files reachable from an entry module, plus the
// npm deps (bare, non-CDN) and the CDN peer specifiers found along the way.
function closure(entryAbs) {
  const files = new Set();       // absolute local .js paths
  const npm = new Set();         // bare install-time specifiers (lit, …)
  const seen = new Set();
  const stack = [entryAbs];
  while (stack.length) {
    const f = stack.pop();
    if (seen.has(f)) continue;
    seen.add(f);
    files.add(f);
    const code = read(f);
    for (const spec of specifiers(code)) {
      if (isRelative(spec)) {
        const r = resolveLocal(f, spec);
        if (r && !seen.has(r)) stack.push(r);
      } else {
        npm.add(spec); // any bare specifier is an install-time npm dep
      }
    }
  }
  return { files: [...files], npm: [...npm] };
}

// Optional CDN tiers a file set lazy-loads at runtime → {pkg: version-range}.
// Pulled from the `const … = "https://esm.sh/<pkg>@<ver>"` lines in tier files.
const CDN_RE = /["']https:\/\/esm\.sh\/((?:@[^/"'@]+\/)?[^/"'@]+)@([^/"'\s]+)/g;
function peerDeps(files) {
  const peers = {};
  for (const f of files) {
    let m;
    const code = read(f);
    while ((m = CDN_RE.exec(code))) {
      const pkg = m[1], ver = m[2];
      if (!peers[pkg]) peers[pkg] = `^${ver}`;
    }
  }
  return peers;
}

// The `var(--work-*)` tokens referenced across a file set (the design-contract
// slice the element consumes).
const TOKEN_RE = /var\(\s*(--work-[a-z0-9-]+)/g;
function tokensUsed(files) {
  const t = new Set();
  for (const f of files) {
    let m;
    const code = read(f);
    while ((m = TOKEN_RE.exec(code))) t.add(m[1]);
  }
  return [...t].sort();
}

// install-time npm deps → {pkg: version} from package.json or a sane default.
const PKG = JSON.parse(read(join(ROOT, "package.json")));
const PKG_DEPS = { ...(PKG.dependencies || {}), ...(PKG.peerDependencies || {}) };
function npmDeps(specs) {
  const deps = {};
  for (const s of specs) {
    const pkg = s.startsWith("@") ? s.split("/").slice(0, 2).join("/") : s.split("/")[0];
    deps[pkg] = PKG_DEPS[pkg] || "*";
  }
  return deps;
}

// ── CEM ───────────────────────────────────────────────────────────────────────
const cem = JSON.parse(read(CEM_PATH));
const byTag = new Map(); // tag → {module, decl}
for (const m of cem.modules) {
  for (const d of m.declarations || []) {
    if (d.customElement && d.tagName) byTag.set(d.tagName, { module: m.path, decl: d });
  }
}

// ── emit ────────────────────────────────────────────────────────────────────
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const relSrc = (abs) => relative(ROOT, abs).split("\\").join("/");

// theme item — the design contract every element registryDepends on.
function themeItem() {
  const tokensCss = join(SRC, "theme", "tokens.css");
  const files = [{
    path: relSrc(tokensCss),
    type: "registry:style",
    target: "workponents/theme/tokens.css",
    content: read(tokensCss),
  }];
  // ship the theme runtime (registry.js / bridge.css) when present, so a
  // consumer also gets applyTheme/registerTheme + the --color-* host alias.
  for (const extra of ["theme/registry.js", "theme/bridge.css"]) {
    const p = join(SRC, extra);
    if (existsSync(p)) files.push({
      path: relSrc(p), type: "registry:lib", target: `workponents/${extra}`, content: read(p),
    });
  }
  const contractPath = join(ROOT, "theme-contract.json");
  let cssVars = [];
  if (existsSync(contractPath)) {
    const contract = JSON.parse(read(contractPath));
    // theme-contract keys are bare (`work-bg`); normalize to the `--work-*` form.
    cssVars = Object.keys(contract.tokens || {})
      .map((k) => (k.startsWith("--") ? k : `--${k}`))
      .filter((k) => k.startsWith("--work-"))
      .sort();
    files.push({
      path: "theme-contract.json", type: "registry:lib",
      target: "workponents/theme-contract.json", content: read(contractPath),
    });
  }
  return {
    $schema: SCHEMA,
    name: "theme",
    type: "registry:style",
    domain: "theme",
    description: "The --work-* design contract: tokens.css + the theme-contract + the applyTheme/registerTheme runtime. Every component registryDepends on it.",
    dependencies: {},
    peerDependencies: {},
    registryDependencies: [],
    cssVars,
    tokens: cssVars,
    files,
  };
}

function elementItem(tag) {
  const { module, decl } = byTag.get(tag);
  const entryAbs = join(ROOT, module);
  // The element file self-registers (calls define() at module load), so the
  // copy-in needs only the entry's transitive closure — NOT the domain barrel
  // (which would drag in sibling elements). A lean copy-in: just this tag's deps.
  const { files: localFiles, npm } = closure(entryAbs);
  const litSpecs = npm.filter(isLit);
  const otherNpm = npm.filter((s) => !isLit(s));
  const deps = npmDeps([...litSpecs, ...otherNpm]);
  const peers = peerDeps(localFiles);
  const tokens = tokensUsed(localFiles);

  // registryDependencies — the cross-item edges (shadcn style).
  const regDeps = ["theme"];
  if (localFiles.some((f) => f.includes(`${join("src", "data")}`) || f.includes("/data/"))) regDeps.push("data");
  if (localFiles.some((f) => f.includes("/validate/"))) regDeps.push("validate");

  // copy-in file records, entry first then deterministic order.
  const ordered = [entryAbs, ...localFiles.filter((f) => f !== entryAbs).sort()];
  const fileRecords = ordered.map((abs) => ({
    path: relSrc(abs),
    type: abs === entryAbs ? "registry:element" : "registry:lib",
    target: `workponents/${relSrc(abs).replace(/^src\//, "")}`,
    content: read(abs),
  }));

  return {
    $schema: SCHEMA,
    name: tag,
    type: "registry:element",
    domain: decl.domain || "core",
    className: decl.name,
    module,
    description: `Copy-in of <${tag}> and its transitive dependency set (core${regDeps.includes("data") ? " + data" : ""}${regDeps.includes("validate") ? " + validate" : ""} + tokens).`,
    dependencies: deps,
    peerDependencies: peers,
    registryDependencies: [...new Set(regDeps)],
    cssVars: tokens,
    tokens,
    attributes: (decl.attributes || []).map((a) => a.name),
    events: (decl.events || []).map((e) => e.name),
    files: fileRecords,
  };
}

// shared library items (data / validate) so element regDeps resolve.
function libItem(name, dir, description) {
  const entry = join(SRC, dir, "index.js");
  if (!existsSync(entry)) return null;
  const { files: localFiles, npm } = closure(entry);
  return {
    $schema: SCHEMA,
    name,
    type: "registry:lib",
    domain: name,
    description,
    dependencies: npmDeps(npm.filter((s) => !isLit(s) ? true : true)),
    peerDependencies: peerDeps(localFiles),
    registryDependencies: ["theme"],
    cssVars: tokensUsed(localFiles),
    tokens: tokensUsed(localFiles),
    files: [entry, ...localFiles.filter((f) => f !== entry).sort()].map((abs) => ({
      path: relSrc(abs), type: "registry:lib",
      target: `workponents/${relSrc(abs).replace(/^src\//, "")}`, content: read(abs),
    })),
  };
}

function writeItem(item) {
  writeFileSync(join(OUT, `${item.name}.json`), JSON.stringify(item, null, 2) + "\n");
}

// theme + shared libs
writeItem(themeItem());
const dataItem = libItem("data", "data", "The shared SQLite data engine (runtime VFS · sqlite-wasm · memory floor) behind the Host seam — what tables / data-viz / maps / search query.");
const validateItem = libItem("validate", "validate", "The schema-validation layer the forms domain consumes (parseSchema / validateRecord).");
if (dataItem) writeItem(dataItem);
if (validateItem) writeItem(validateItem);

// every element
const tags = [...byTag.keys()].sort();
const items = tags.map(elementItem);
for (const item of items) writeItem(item);

// ── index ─────────────────────────────────────────────────────────────────────
const byDomain = {};
for (const item of items) {
  (byDomain[item.domain] = byDomain[item.domain] || []).push(item);
}
const domains = Object.keys(byDomain).sort().map((domain) => ({
  domain,
  tagline: DOMAIN_TAGLINES[domain] || "",
  components: byDomain[domain]
    .map((i) => ({
      name: i.name,
      attributes: i.attributes,
      events: i.events,
      registryDependencies: i.registryDependencies,
    }))
    .sort((a, b) => a.name.localeCompare(b.name)),
}));
const index = {
  $schema: "https://workbooks.sh/schema/registry-index.json",
  name: PKG.name,
  version: PKG.version,
  homepage: "https://workbooks.sh",
  description: "shadcn-style copy-in registry of themed <work-*> custom elements. Copy a component + its deps + the theme into your project.",
  style: { name: "theme", type: "registry:style" },
  libs: [dataItem, validateItem].filter(Boolean).map((i) => i.name),
  totals: { components: items.length, domains: domains.length },
  domains,
};
writeFileSync(join(OUT, "index.json"), JSON.stringify(index, null, 2) + "\n");

// ── VS Code html.customData (tag autocomplete) ────────────────────────────────
const customData = {
  version: 1.1,
  tags: items.map((i) => ({
    name: i.name,
    description: `${i.description}\n\nDomain: ${i.domain}. Install: copy-in via the workponents registry (${i.name} + ${i.registryDependencies.join(" + ")}).`,
    attributes: i.attributes.map((name) => ({ name })),
    references: [{ name: "workponents", url: "https://workbooks.sh" }],
  })),
};
writeFileSync(join(OUT, "html-custom-data.json"), JSON.stringify(customData, null, 2) + "\n");

// ── README ────────────────────────────────────────────────────────────────────
writeFileSync(join(OUT, "README.md"), readme(index));

console.log(`registry: ${items.length} components across ${domains.length} domains`);
console.log(`  + theme${dataItem ? " + data" : ""}${validateItem ? " + validate" : ""} library items`);
console.log(`  → registry/index.json, registry/*.json, registry/html-custom-data.json`);

function readme(idx) {
  const domainList = idx.domains
    .map((d) => `- **${d.domain}** — ${d.tagline} (${d.components.map((c) => `\`${c.name}\``).join(", ")})`)
    .join("\n");
  return `# workponents registry — copy-in distribution

The shadcn-style registry: instead of \`npm install\`-ing a black box, a consumer
**copies a themed \`<work-*>\` element and its transitive dependency set into
their own project**, where they own and can edit the source. Generated entirely
from \`src/**\` + the CEM (\`custom-elements.json\`) — additive tooling, never a
hand-maintained manifest.

Regenerate deterministically:

\`\`\`sh
npm run registry
\`\`\`

## The copy-in model

Each \`registry/<tag>.json\` is a self-contained recipe:

| field | meaning |
|-------|---------|
| \`files\` | the **transitive closure** of the element's local source — the entry element file (\`registry:element\`, which self-registers the tag via \`define()\`) plus every \`../core/*\`, \`../../data/*\`, \`../../validate/*\`, and tier file it imports (\`registry:lib\`). Lean: only this tag's deps, not its sibling elements. Each carries \`content\` + a \`target\` (where it lands in the consumer's tree). |
| \`dependencies\` | install-time npm packages the file set imports as bare specifiers (e.g. \`lit\`). |
| \`peerDependencies\` | **optional** CDN engines the element lazy-\`import()\`s at runtime (Observable Plot, MapLibre, CodeMirror, MiniSearch) — only needed to light up the heavy tier. |
| \`registryDependencies\` | other registry items this one pulls — always \`theme\`; \`data\` for the data surfaces; \`validate\` for forms. |
| \`cssVars\` / \`tokens\` | the \`--work-*\` design-contract slice the element consumes. |
| \`attributes\` / \`events\` / \`domain\` | from the CEM. |

To install a component, a consumer (or a CLI/agent) resolves it recursively:

1. Copy every file in \`files\` to its \`target\`.
2. Copy each \`registryDependencies\` item's files (\`theme\` → \`tokens.css\` + the
   theme-contract + \`applyTheme\`/\`registerTheme\`; \`data\`/\`validate\` as needed).
3. \`npm install\` the union of \`dependencies\`; optionally the
   \`peerDependencies\` to enable the heavy tier.
4. Import the element file (registers the tag) and drop \`<${idx.domains[0].components[0].name} …>\` in markup.

Every component pulls **theme**, so a copy-in always lands with the design
contract — no element ships an orphaned token.

## Components (${idx.totals.components} tags · ${idx.totals.domains} domains)

${domainList}

Library items: ${idx.libs.map((l) => `\`${l}\``).join(", ")} · style item: \`theme\`.

## Editor support

\`registry/html-custom-data.json\` is a VS Code \`html.customData\` file — point
\`"html.customData": ["./workponents/registry/html-custom-data.json"]\` at it for
\`<work-*>\` tag + attribute autocomplete.

## Relationship to the toolkit \`#+REQUIRES\` graph

This registry is the **artifact-side mirror** of the runtime's toolkit
dependency graph. A component toolkit declares its dependencies with
\`#+REQUIRES\`; the runtime computes a **transitive closure at subscription time**
(dedup + cycle-detect, a DAG) and flattens it into the agent's prompt index.

The registry computes the **same closure statically** — by following each
element's \`import\` graph — and materializes it as copy-in \`files\` +
\`registryDependencies\`. One dependency idea, two distribution surfaces:

| | toolkit graph (runtime) | registry (artifact) |
|---|---|---|
| edge | \`#+REQUIRES\` | \`import "…"\` / \`registryDependencies\` |
| closure | computed at subscription time | computed at \`npm run registry\` |
| result | flattened prompt index | copied-in source tree |
| dedup / cycle | yes (DAG) | yes (visited set) |

A consumer subscribing to a component toolkit and a consumer copying it in get
the **same transitive dependency set** — resolved by the same idea, delivered
through the surface that fits where the component runs.
`;
}
