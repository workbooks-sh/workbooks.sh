#!/usr/bin/env node
// `work component new <name> [domain]` — scaffold a NEW work-* web component that
// passes the 5-gate out of the box. Web-component supremacy: creating a capability =
// authoring a themed, shadow-isolated custom element, not a bespoke CLI binary.
//
// It writes the element (token-only, no literal colors), registers it in the domain
// barrel, adds a gate fixture, and regenerates the CEM. Then you seed a visual
// baseline + build:  npm run gate:baseline work-<name> && npm run build
//
//   node tools/scaffold.mjs <name> [domain]
//   npm run new -- <name> [domain]

import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const ELEMENTS = join(ROOT, "src", "elements");

// The element template — PURE (no IO), exported so the eval can assert it stays
// token-clean + well-formed without scaffolding into the real tree. Token-only (no
// literal colors → passes the token gate), shadow-isolated, mirrors the wb-metric card
// pattern so it paints + flips light/dark out of the box.
export function elementSource({ tag, cls, name, importPath }) {
  return `import { WbElement, html, css, define } from "${importPath}";

/**
 * <${tag}> — TODO: one-line description (what it shows, when to reach for it).
 * Themed ONLY via --work-* tokens (no literal colors) and shadow-isolated, so it
 * inherits the workbook theme and survives hostile host CSS. Edit render()/styles
 * for real content; this scaffold already passes \`work gate ${tag}\`.
 */
export class ${cls} extends WbElement {
  static props = ["label"];

  static styles = css\`
    :host { display: block; font-family: var(--work-font); color: var(--work-fg); }
    .shell {
      border: 1px solid var(--work-border);
      border-radius: var(--work-radius);
      background: var(--work-surface);
      box-shadow: var(--work-shadow-sm);
      padding: var(--work-space-3) var(--work-space-4);
    }
    .label {
      font-family: var(--work-font-mono);
      font-size: var(--work-text-sm);
      letter-spacing: 0.04em;
      text-transform: uppercase;
      color: var(--work-fg-muted);
    }
    .body { margin-top: var(--work-space-2); }
  \`;

  render() {
    return html\`
      <div class="shell">
        <div class="label">\${this.attr("label", "${name}")}</div>
        <div class="body"><slot></slot></div>
      </div>
    \`;
  }
}

define("${tag}", ${cls});
`;
}

// Tag/class/domain derivation — also exported (pure) so the eval can check the mapping.
export function derive(rawName, rawDomain, domains) {
  const name = String(rawName || "").replace(/^work-/, "");
  if (!/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/.test(name)) throw new Error(`name must be kebab-case (got "${rawName}")`);
  const domain = rawDomain || "core";
  if (domain !== "core" && !domains.includes(domain)) {
    throw new Error(`unknown domain "${domain}" — pick one of: core ${domains.join(" ")}`);
  }
  const tag = `work-${name}`;
  const cls = "Wb" + name.split("-").map((p) => p[0].toUpperCase() + p.slice(1)).join("");
  const importPath = domain === "core" ? "./core/element.js" : "../../core/element.js";
  return { name, domain, tag, cls, importPath };
}

function scaffold() {
  const die = (m) => {
    console.error(`✗ ${m}`);
    process.exit(1);
  };
  const [, , rawName, rawDomain] = process.argv;
  if (!rawName) die("usage: node tools/scaffold.mjs <name> [domain]   (name = kebab-case, e.g. status-card)");

  const domains = readdirSync(ELEMENTS, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
  let d;
  try {
    d = derive(rawName, rawDomain, domains);
  } catch (e) {
    die(e.message);
  }
  const { name, domain, tag, cls, importPath } = d;

  const elDir = domain === "core" ? ELEMENTS : join(ELEMENTS, domain);
  const elFile = join(elDir, `work-${name}.js`);
  if (existsSync(elFile)) die(`element already exists: ${elFile}`);

  const cemPath = join(ROOT, "custom-elements.json");
  if (existsSync(cemPath) && readFileSync(cemPath, "utf8").includes(`"${tag}"`)) {
    die(`tag ${tag} is already registered in custom-elements.json`);
  }

  // 1. the element file.
  writeFileSync(elFile, elementSource({ tag, cls, name, importPath }));

  // 2. register in the barrel so the build picks it up.
  const exportLine = `export { ${cls} } from "./work-${name}.js";\n`;
  if (domain === "core") {
    appendExport(join(ROOT, "src", "index.js"), exportLine.replace("./work", "./elements/work"));
  } else {
    const barrel = join(elDir, "index.js");
    if (existsSync(barrel)) appendExport(barrel, exportLine);
    else {
      writeFileSync(barrel, `// workponents · ${domain} domain\n${exportLine}`);
      console.warn(`! created a new barrel ${barrel} — add it to src/index.js if this is a new domain`);
    }
  }

  // 3. a gate fixture so `work gate` can render it.
  const fixturesPath = join(ROOT, "tools", "gate", "fixtures.js");
  let fx = readFileSync(fixturesPath, "utf8");
  if (!fx.includes(`"${tag}"`)) {
    fx = fx.replace(
      /export const FIXTURES = \{\n/,
      `export const FIXTURES = {\n  "${tag}": { attrs: { label: "Example" }, html: "Scaffolded content" },\n`,
    );
    writeFileSync(fixturesPath, fx);
  }

  // 4. regenerate the CEM (source-reflected — picks up the new define()).
  try {
    execFileSync("node", ["tools/cem.mjs"], { cwd: ROOT, stdio: "inherit" });
  } catch {
    console.warn("! could not regenerate the CEM — run `npm run cem`");
  }

  console.log(`\n✓ scaffolded ${tag}`);
  console.log(`  element : ${elFile.replace(ROOT + "/", "")}`);
  console.log(`  class   : ${cls}   tag: ${tag}   domain: ${domain}`);
  console.log(`\nNext:`);
  console.log(`  npm run gate:baseline ${tag}   # seed the visual baseline`);
  console.log(`  npm run gate ${tag}            # all 5 gates must pass`);
  console.log(`  npm run build                  # include it in dist/workponents.js`);
}

function appendExport(file, line) {
  const cur = existsSync(file) ? readFileSync(file, "utf8") : "";
  if (!cur.includes(line.trim())) writeFileSync(file, cur + (cur.endsWith("\n") || !cur ? "" : "\n") + line);
}

// Run only when executed directly; import (the eval) gets the pure exports.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) scaffold();
