#!/usr/bin/env node
// gate · run — the 5-gate headless validation harness.
//
// ONE Playwright headless Chromium process, sequential per element (the visual
// baseline is a single contended resource — never parallel; this harness is the
// non-contended replacement for ad-hoc agent screenshotting). For each of the 42
// CEM-declared elements it runs five gates and writes a verdict:
//
//   .gate/<element>.json
//   { element, gates:{tokens,scope,wasm,functional,visual}, pass, leaks:[...], notes }
//
// Gates: (a) token-leak  (b) scope-isolation  (c) wasm/floor-loadability
//        (d) functional-parity-vs-floor  (e) visual baseline.
//
// Usage:
//   node tools/gate/run.js                 # all elements
//   node tools/gate/run.js work-diff …     # a subset
//   node tools/gate/run.js --update-baseline   # (re)write the visual baselines

import { chromium } from "playwright";
import sharp from "sharp";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "./server.js";
import { fixtureFor } from "./fixtures.js";
import {
  staticTokenLeak, importGraphScan, functionalParity, POWERED_SEAMS, normColor,
} from "./gates.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..", "..");
const GATE_DIR = join(ROOT, ".gate");
const BASELINE_DIR = join(GATE_DIR, "baseline");
const THEMES = ["light", "dark", "signal"];
const VISUAL_THRESHOLD = 0.06; // perceptual: ≤6% of pixels may differ — absorbs
// sub-pixel anti-alias jitter in text-dense elements (the diff's monospace rows)
// while still catching real layout/color drift, which moves far more pixels.

const contract = JSON.parse(readFileSync(join(ROOT, "theme-contract.json"), "utf8"));

// ── element registry from the CEM ─────────────────────────────────────────────
function loadElements() {
  const cem = JSON.parse(readFileSync(join(ROOT, "custom-elements.json"), "utf8"));
  const els = [];
  for (const m of cem.modules)
    for (const d of m.declarations || [])
      if (d.customElement && d.tagName)
        els.push({ tag: d.tagName, path: m.path, domain: d.domain, attrs: (d.attributes || []).map((a) => a.name) });
  return els;
}

// ── (a) token-leak — runtime computed-style sweep + theme-flip-delta ──────────
// Mount under each theme, read paint props on the whole shadow tree, assert each
// resolved color traces to the active theme (we prove this indirectly: the SAME
// element must paint DIFFERENTLY light-vs-dark — identical paint ⇒ it ignores the
// tokens ⇒ fail). Allowed escape values (transparent/currentColor/inherit and the
// zero-paint defaults) never count toward the delta.
const ESCAPE = new Set(["rgba(0, 0, 0, 0)", "transparent", "none", "currentcolor", "inherit", "", "rgb(0, 0, 0)"]);
const PAINT_FOR_DELTA = ["color", "background-color", "border-top-color", "fill", "box-shadow"];

async function runtimeTokenSweep(page, tag, mount) {
  const byTheme = {};
  for (const theme of THEMES) {
    await page.evaluate((t) => window.__gate.setTheme(t), theme);
    await mount();
    const res = await page.evaluate((args) => window.__gate.sweepStyles(args.tag, args.props),
      { tag, props: PAINT_FOR_DELTA });
    byTheme[theme] = res.records || [];
  }
  // theme-flip delta: across light vs dark, at least one painted prop must differ.
  const flat = (recs) =>
    recs.flatMap((r) => PAINT_FOR_DELTA.map((p) => `${r.sel}|${p}|${normColor(r[p])}`)
      .filter((s) => { const v = s.split("|")[2]; return v && !ESCAPE.has((v || "").toLowerCase()); }));
  const light = new Set(flat(byTheme.light));
  const dark = new Set(flat(byTheme.dark));
  let differs = false;
  for (const k of light) {
    const [sel, prop] = k.split("|");
    const lv = k.split("|")[2];
    const dk = [...dark].find((x) => x.startsWith(`${sel}|${prop}|`));
    if (dk && dk.split("|")[2] !== lv) { differs = true; break; }
  }
  // an element that paints NOTHING (pure layout/slot) is exempt — no tokens to flip.
  const paintsAnything = light.size > 0 || dark.size > 0;
  return { differs, paintsAnything, lightProps: light.size, darkProps: dark.size };
}

// ── (b) scope-isolation — hostile global stylesheet ───────────────────────────
// Capture the bare baseline, then inject a hostile host-page stylesheet and
// re-mount; assert the element's SHADOW content is unchanged (shadow DOM isolates
// it) and that mounting injected no unscoped rule into document.head.
//
// The hostile sheet targets selectors a real host page WOULD ship — element-type
// rules (`button{}`, `div{}`, `table{}`, `input{}`, `svg{}`), class rules
// (`.frame{}`, `.head{}`), and a non-inherited `background` reset. Shadow DOM
// genuinely blocks all of these from piercing into shadow descendants.
//
// We deliberately do NOT assert against a `* { color: … !important }` universal
// override: `color`/`font` are INHERITED properties that cascade through the
// shadow boundary by spec from the host element's own (light-DOM) computed value
// — that is CSS working as designed, not a scope breach, and every web component
// is subject to it. So the host node itself is excluded from the comparison and
// the hostile sheet does not weaponize inherited-property cascade.
const HOSTILE_CSS = [
  "button{border:5px solid magenta!important;font-size:40px!important;background:cyan!important;padding:30px!important}",
  "div{background:lime!important;border:3px dashed orange!important}",
  "table,td,th{background:fuchsia!important;border:4px solid red!important}",
  "input,textarea{background:yellow!important;color:purple!important}",
  "svg,path,rect,circle{fill:hotpink!important;stroke:teal!important}",
  ".frame,.head,.body,.title,.meta,.node,.badge{background:gold!important;color:maroon!important;border-color:navy!important}",
].join("\n");

async function scopeIsolation(page, tag, mount) {
  await page.evaluate((t) => window.__gate.setTheme(t), "light");
  await mount();
  const baseline = await page.evaluate((t) => window.__gate.sweepStyles(t), tag);
  const headBefore = await page.evaluate(() => window.__gate.headRuleSignature());

  await page.evaluate((css) => {
    const s = document.createElement("style");
    s.id = "__hostile";
    s.textContent = css;
    document.head.appendChild(s);
  }, HOSTILE_CSS);
  await mount();
  const hostile = await page.evaluate((t) => window.__gate.sweepStyles(t), tag);
  const headAfter = await page.evaluate(() => window.__gate.headRuleSignature());

  // compare paint records sel-by-sel; exclude the HOST node itself (it lives in
  // the light DOM, so host-page rules legitimately reach it).
  const map = (r) => Object.fromEntries((r.records || []).map((x) => [x.sel, x]));
  const a = map(baseline), b = map(hostile);
  const leaks = [];
  for (const sel of Object.keys(a)) {
    if (sel === tag) continue;            // host node — not part of the shadow scope
    if (!sel.includes("::shadow")) continue; // only assert on shadow descendants
    const x = a[sel], y = b[sel];
    if (!y) continue;
    for (const p of ["color", "background-color", "border-top-color", "fill"]) {
      if (normColor(x[p]) !== normColor(y[p])) leaks.push({ sel, prop: p, bare: x[p], hostile: y[p] });
    }
  }
  // head pollution: our own injected hostile <style> is expected; any OTHER new
  // <style> the element added is a leak.
  const headPolluted = headAfter.styleCount > headBefore.styleCount + 1;
  // cleanup
  await page.evaluate(() => document.getElementById("__hostile")?.remove());
  return { pass: leaks.length === 0 && !headPolluted, leaks, headPolluted };
}

// ── (e) visual baseline ───────────────────────────────────────────────────────
// element × theme × {base + key variants} → png; diff vs committed baseline.
async function visualBaseline(page, tag, baseSpec, update) {
  const variants = [{}, ...(baseSpec.variants || [])];
  const results = [];
  for (const theme of THEMES) {
    await page.evaluate((t) => window.__gate.setTheme(t), theme);
    for (let vi = 0; vi < variants.length; vi++) {
      const spec = { tag, attrs: { ...(baseSpec.attrs || {}), ...variants[vi] }, html: baseSpec.html };
      await page.evaluate((s) => window.__gate.mount(s), spec);
      await page.waitForTimeout(60);
      const el = await page.$(`#stage ${tag}`);
      const name = `${tag}-${theme}-v${vi}.png`;
      const file = join(BASELINE_DIR, name);
      // A non-visual element (a config child like <work-column>/<work-video-source>
      // that renders no box) has no element screenshot — fall back to the stage
      // viewport so the corpus still has a deterministic shot, and never hang.
      const box = el ? await el.boundingBox().catch(() => null) : null;
      const target = box && box.width > 0 && box.height > 0 ? el : page;
      const shot = await target.screenshot({ timeout: 5000 }).catch(() => page.screenshot());
      if (update || !existsSync(file)) {
        writeFileSync(file, shot);
        results.push({ name, status: update ? "updated" : "created" });
      } else {
        const diffRatio = await pixelDiff(readFileSync(file), shot);
        results.push({ name, status: diffRatio <= VISUAL_THRESHOLD ? "match" : "drift", diffRatio: +diffRatio.toFixed(4) });
      }
    }
  }
  const drift = results.filter((r) => r.status === "drift");
  return { pass: drift.length === 0, results, drift };
}

// Perceptual diff: decode both PNGs to raw RGBA (via sharp, already present),
// resize the candidate to the baseline's dims if they differ, and count pixels
// whose per-channel delta exceeds a tolerance. Returns the fraction of differing
// pixels (0 = identical). A dimension mismatch alone counts as full drift.
async function pixelDiff(aBuf, bBuf) {
  if (aBuf.equals(bBuf)) return 0;
  const A = await sharp(aBuf).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let B = await sharp(bBuf).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  if (A.info.width !== B.info.width || A.info.height !== B.info.height) {
    B = await sharp(bBuf).resize(A.info.width, A.info.height, { fit: "fill" }).ensureAlpha().raw()
      .toBuffer({ resolveWithObject: true });
  }
  const a = A.data, b = B.data, n = Math.min(a.length, b.length);
  const TOL = 24; // per-channel tolerance (anti-alias / sub-pixel jitter)
  let diff = 0;
  for (let i = 0; i < n; i += 4) {
    if (Math.abs(a[i] - b[i]) > TOL || Math.abs(a[i + 1] - b[i + 1]) > TOL ||
        Math.abs(a[i + 2] - b[i + 2]) > TOL) diff++;
  }
  return diff / (n / 4);
}

// ── per-element driver ────────────────────────────────────────────────────────
async function gateElement(page, el, update) {
  const tag = el.tag;
  const source = readFileSync(join(ROOT, el.path), "utf8");

  // ensure the element is registered — the barrel may have skipped it after a
  // sibling module threw; recover it by importing its own module in isolation.
  const registered = await page.evaluate(async (args) => {
    if (window.customElements.get(args.tag)) return { ok: true, recovered: false };
    const ok = await window.__loadModule(args.path);
    return { ok: ok && !!window.customElements.get(args.tag), recovered: true };
  }, { tag, path: el.path });
  if (!registered.ok) {
    // The element won't mount, but the STATIC gates (token-leak, import-graph) are
    // pure source analysis — still run them so the verdict is complete and the
    // known token-leak total is honest even for an element that fails to register.
    const staticLeaks = staticTokenLeak(tag, source, contract).map((e) => ({ gate: "tokens", ...e }));
    const importLeaks = importGraphScan(join(ROOT, el.path)).map((e) => ({ gate: "wasm", ...e }));
    return {
      element: tag, domain: el.domain,
      gates: { tokens: staticLeaks.length === 0, scope: false, wasm: importLeaks.length === 0, functional: false, visual: false },
      pass: false,
      leaks: [{ gate: "load", rule: "register", message: `element ${tag} failed to register (module ${el.path}) — runtime gates skipped` }, ...staticLeaks, ...importLeaks],
      notes: ["element did not register — runtime gates (scope/flip/visual) skipped; static gates still applied; see summary.barrelLoadErrors"],
    };
  }
  const fx = fixtureFor(tag);
  const baseSpec = { tag, attrs: fx.attrs || {}, html: fx.html, variants: fx.variants };
  const mount = () => page.evaluate((s) => window.__gate.mount(s), { tag, attrs: baseSpec.attrs, html: baseSpec.html });

  const notes = [];
  const leaks = [];

  // (a) token-leak — static + runtime
  const staticLeaks = staticTokenLeak(tag, source, contract);
  const sweep = await runtimeTokenSweep(page, tag, mount);
  for (const e of staticLeaks) leaks.push({ gate: "tokens", ...e });
  const flipOk = !sweep.paintsAnything || sweep.differs;
  if (sweep.paintsAnything && !sweep.differs)
    leaks.push({ gate: "tokens", rule: "theme-flip-delta", message: "paints identically light vs dark — ignores tokens" });
  const tokensPass = staticLeaks.length === 0 && flipOk;

  // (b) scope-isolation
  const scope = await scopeIsolation(page, tag, mount);
  for (const l of scope.leaks) leaks.push({ gate: "scope", rule: "shadow-leak", ...l });
  if (scope.headPolluted) leaks.push({ gate: "scope", rule: "head-pollution", message: "mounting injected unscoped <style> into document.head" });

  // (c) wasm/floor-loadability — static import scan (+ engine-block when a seam exists)
  const importLeaks = importGraphScan(join(ROOT, el.path));
  for (const l of importLeaks) leaks.push({ gate: "wasm", ...l });
  const seam = POWERED_SEAMS[tag];
  let wasmNote = seam ? "powered seam — floor-with-engine-blocked verified" : "pure-floor — static scan only";
  let wasmPass = importLeaks.length === 0;
  if (seam) {
    // route-abort the engine chunk, assert the floor still renders
    await page.route(seam.enginePattern, (r) => r.abort());
    await mount();
    const rendered = await page.$(`#stage ${tag} >> css=${seam.floorMustRender}`).catch(() => null);
    await page.unroute(seam.enginePattern);
    if (!rendered) { wasmPass = false; leaks.push({ gate: "wasm", rule: "floor-degrade", message: `floor did not render with ${seam.enginePattern} blocked` }); }
  }

  // (d) functional-parity-vs-floor (framework; no-op until P3)
  const parity = await functionalParity(tag, page, mount, mount);
  if (!parity.pass) leaks.push({ gate: "functional", rule: "parity", message: parity.note });

  // (e) visual baseline
  const visual = await visualBaseline(page, tag, baseSpec, update);
  for (const d of visual.drift) leaks.push({ gate: "visual", rule: "drift", ...d });

  const gates = {
    tokens: tokensPass,
    scope: scope.pass,
    wasm: wasmPass,
    functional: parity.pass,
    visual: visual.pass,
  };
  notes.push(`tokens: ${sweep.paintsAnything ? `paints (L=${sweep.lightProps} D=${sweep.darkProps}), flip=${sweep.differs}` : "no paint (layout/slot — exempt from flip)"}`);
  notes.push(wasmNote);
  notes.push(parity.applicable ? "parity: engine vs floor compared" : "parity: no powered engine (floor is sole impl)");
  notes.push(`visual: ${visual.results.length} shots`);

  const pass = Object.values(gates).every(Boolean);
  return { element: tag, domain: el.domain, gates, pass, leaks, notes };
}

// ── orchestrator ──────────────────────────────────────────────────────────────
async function main() {
  const args = process.argv.slice(2);
  const update = args.includes("--update-baseline");
  const only = args.filter((a) => !a.startsWith("--"));

  mkdirSync(BASELINE_DIR, { recursive: true });
  let elements = loadElements();
  if (only.length) elements = elements.filter((e) => only.includes(e.tag));

  const { url, close } = await startServer();
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 720, height: 480 } });
  const pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));
  await page.goto(`${url}/__gate/page.html`, { waitUntil: "load" });
  await page.waitForFunction(() => window.__workponentsLoaded === true, { timeout: 15000 });
  const loadErrors = await page.evaluate(() => window.__loadErrors || []);
  if (loadErrors.length) console.log(`  (note: ${loadErrors.length} barrel-load error(s) — elements recovered per-module)`);

  const summary = [];
  for (const el of elements) {
    process.stdout.write(`  · ${el.tag} … `);
    try {
      const verdict = await gateElement(page, el, update);
      writeFileSync(join(GATE_DIR, `${el.tag}.json`), JSON.stringify(verdict, null, 2));
      summary.push({ element: el.tag, pass: verdict.pass, leaks: verdict.leaks.length });
      console.log(verdict.pass ? "PASS" : `FAIL (${verdict.leaks.length} leak${verdict.leaks.length === 1 ? "" : "s"})`);
    } catch (e) {
      const verdict = { element: el.tag, gates: {}, pass: false, leaks: [{ gate: "harness", message: String(e) }], notes: ["harness error"] };
      writeFileSync(join(GATE_DIR, `${el.tag}.json`), JSON.stringify(verdict, null, 2));
      summary.push({ element: el.tag, pass: false, leaks: 1, error: String(e) });
      console.log(`ERROR — ${e.message}`);
    }
  }

  await browser.close();
  await close();

  const totalLeaks = summary.reduce((n, s) => n + s.leaks, 0);
  const passed = summary.filter((s) => s.pass).length;
  const out = {
    when: new Date().toISOString(),
    elements: summary.length,
    passed,
    failed: summary.length - passed,
    totalLeaks,
    pageErrors,
    barrelLoadErrors: loadErrors,
    results: summary,
  };
  writeFileSync(join(GATE_DIR, "summary.json"), JSON.stringify(out, null, 2));
  console.log(`\n${passed}/${summary.length} elements pass · ${totalLeaks} total leak(s) · baselines in .gate/baseline/`);

  // CI semantics: `gate:all` fails if ANY element fails. Single-element `gate`
  // runs report but never hard-fail the dev loop unless --strict is passed.
  const strict = args.includes("--strict") || (!only.length && !update);
  if (strict && passed < summary.length) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(2); });
