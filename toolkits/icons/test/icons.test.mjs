#!/usr/bin/env node
/**
 * icons.test.mjs — drives the committed src/index.js as a CLI (Node mode) and
 * asserts the wb-5fl.16 gates + grammar-sync invariants. Run:
 *
 *   node test/icons.test.mjs
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const root = path.join(path.dirname(new URL(import.meta.url).pathname), "..");
const entry = path.join(root, "src/index.js");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`✓ ${name}`);
  } catch (e) {
    failures++;
    console.error(`✗ ${name}: ${e.message}`);
  }
}
const run = (...args) =>
  execFileSync(process.execPath, [entry, ...args], { encoding: "utf8" }).trim();
const runJson = (...args) => JSON.parse(run(...args, "--json"));
const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

// --- the bead's verification gates -----------------------------------------

check('search "rocket" finds mi:rocket and the 🚀 emoji, exact first', () => {
  const hits = runJson("search", "rocket");
  const values = hits.map((h) => h.value);
  assert(values.includes("mi:rocket"), `no mi:rocket in ${values}`);
  assert(values.includes("🚀"), `no 🚀 in ${values}`);
  assert(hits[0].name === "rocket", `top hit not exact: ${hits[0].name}`);
});

check('for-file "main.rs" → mi:rust via the rs extension', () => {
  const hit = runJson("for-file", "main.rs");
  assert(hit.value === "mi:rust", hit.value);
  assert(hit.via.includes("fileExtensions"), hit.via);
});

check('for-file "package.json" → mi:nodejs via fileNames', () => {
  const hit = runJson("for-file", "package.json");
  assert(hit.value === "mi:nodejs", hit.value);
  assert(hit.via.includes("fileNames"), hit.via);
});

check('for-folder "src" → mi:folder-src; --open → the -open twin', () => {
  assert(runJson("for-folder", "src").value === "mi:folder-src", "closed");
  assert(runJson("for-folder", "src", "--open").value === "mi:folder-src-open", "open");
});

check('get "mi:rust" → known material def with a pinned CDN url', () => {
  const hit = runJson("get", "mi:rust");
  assert(hit.kind === "material" && hit.known === true, JSON.stringify(hit));
  assert(/material-icon-theme@\d.+\/icons\/rust\.svg$/.test(hit.url), hit.url);
});

check('get "lobe:openai" → known lobe slug with the raw.githubusercontent url', () => {
  const hit = runJson("get", "lobe:openai");
  assert(hit.kind === "lobe" && hit.known === true, JSON.stringify(hit));
  assert(
    hit.url ===
      "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-svg/icons/openai.svg",
    hit.url,
  );
});

// --- grammar-sync + resolution invariants -----------------------------------

check("desktop fallback parity: unknown file/folder → the default defs", () => {
  assert(runJson("for-file", "x.zzznope").value === "mi:file", "file default");
  assert(runJson("for-folder", "zzznope").value === "mi:folder", "folder default");
  assert(runJson("for-folder", "zzznope", "--open").value === "mi:folder-open", "folder-open default");
});

check("multi-dot extensions resolve longest-suffix (d.ts beats ts)", () => {
  const hit = runJson("for-file", "types.d.ts");
  assert(hit.via.includes('"d.ts"'), hit.via);
});

check("legacy lucide values map per LEGACY_GLYPHS (Rocket → mi:rocket)", () => {
  const hit = runJson("get", "lucide:Rocket");
  assert(hit.mapped === "mi:rocket" && hit.known === true, JSON.stringify(hit));
});

check("emoji get reverse-names the char; empty value is the initials case", () => {
  assert(runJson("get", "🚀").name === "rocket", "emoji name");
  assert(runJson("get").kind === "initials", "initials");
});

check("unknown mi: def exits 1 and reports the initials fallback", () => {
  let code = 0;
  try {
    execFileSync(process.execPath, [entry, "get", "mi:zzznope"], { encoding: "utf8" });
  } catch (e) {
    code = e.status;
  }
  assert(code === 1, `exit ${code}`);
});

check("LEGACY_GLYPHS stays in sync with desktop Icon.svelte", () => {
  const svelte = ["../../desktop/src/lib/ui/Icon.svelte", "../../../../desktop/src/lib/ui/Icon.svelte"]
    .map((p) => path.join(root, p))
    .find((p) => fs.existsSync(p));
  if (!svelte) return; // toolkit distributed without the desktop tree — skip
  const cli = fs.readFileSync(path.join(root, "src/cli.js"), "utf8");
  const pairs = [...fs.readFileSync(svelte, "utf8").matchAll(/^\s{4}(\w+): "([\w-]+)",$/gm)];
  assert(pairs.length > 0, "no LEGACY_GLYPHS entries parsed from Icon.svelte");
  for (const [, name, def] of pairs)
    assert(cli.includes(`${name}: "${def}"`), `drift: ${name} → ${def} missing in cli.js`);
});

check("generated src/index.js is fresh (packs match the inlined prologue)", () => {
  const inlined = fs.readFileSync(entry, "utf8").match(/__ICONS_PACKS = (.*);\n/)[1];
  const packs = Object.fromEntries(
    ["material", "lobe", "emoji"].map((n) => [
      n,
      JSON.parse(fs.readFileSync(path.join(root, "packs", `${n}.json`), "utf8")),
    ]),
  );
  assert(inlined === JSON.stringify(packs), "src/index.js stale — run scripts/build-packs.mjs");
});

console.log(failures === 0 ? "\nall checks passed" : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
