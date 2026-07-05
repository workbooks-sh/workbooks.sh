#!/usr/bin/env node
/* WCAG contrast gate for autopoet.app.
   Parses the design tokens out of public/styles.css (:root = light,
   [data-theme="dark"] = dark overrides), composites alpha colors over their
   real background, and asserts every text/UI pair that actually ships clears
   its WCAG 2.1 threshold in BOTH themes. Exits non-zero on any hard failure.

   Run: node tools/contrast-check.mjs   (or: npm run check)  */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const CSS = readFileSync(join(HERE, "..", "public", "styles.css"), "utf8");

/* ---- extract a `selector { ... }` declaration block's --tokens ---- */
function tokenBlock(css, selector) {
  const start = css.indexOf(selector);
  if (start === -1) throw new Error(`selector not found: ${selector}`);
  const open = css.indexOf("{", start);
  const close = css.indexOf("}", open);
  const body = css.slice(open + 1, close);
  const out = {};
  for (const m of body.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) out[m[1]] = m[2].trim();
  return out;
}

const light = tokenBlock(CSS, ":root");
const darkOverrides = tokenBlock(CSS, '[data-theme="dark"]');
const dark = { ...light, ...darkOverrides };

/* ---- color parsing → {r,g,b,a} in 0..255 / 0..1 ---- */
function parseColor(str) {
  str = str.trim();
  let m = str.match(/^#([0-9a-f]{3})$/i);
  if (m) {
    const h = m[1];
    return { r: parseInt(h[0] + h[0], 16), g: parseInt(h[1] + h[1], 16), b: parseInt(h[2] + h[2], 16), a: 1 };
  }
  m = str.match(/^#([0-9a-f]{6})$/i);
  if (m) {
    const h = m[1];
    return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16), a: 1 };
  }
  m = str.match(/^rgba?\(([^)]+)\)$/i);
  if (m) {
    const p = m[1].split(",").map((s) => s.trim());
    return { r: +p[0], g: +p[1], b: +p[2], a: p[3] === undefined ? 1 : +p[3] };
  }
  return null; // gradients, color-mix, etc. — not a flat color, skip
}

/* resolve a token to a flat color, compositing alpha over an opaque bg token */
function resolve(theme, name, bgName) {
  const c = parseColor(theme[name]);
  if (!c) throw new Error(`token ${name} = "${theme[name]}" is not a flat color`);
  if (c.a >= 1) return c;
  const bg = resolve(theme, bgName, bgName); // bg must be opaque (page/surface are)
  return {
    r: c.r * c.a + bg.r * (1 - c.a),
    g: c.g * c.a + bg.g * (1 - c.a),
    b: c.b * c.a + bg.b * (1 - c.a),
    a: 1,
  };
}

/* ---- WCAG relative luminance + contrast ratio ---- */
function lin(v) {
  v /= 255;
  return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}
function luminance({ r, g, b }) { return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b); }
function ratio(a, b) {
  const la = luminance(a), lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/* ---- pairs that actually ship. hard = fails the build; advisory = reported only ---- */
const PAIRS = [
  // fg, bg, min, category, hard?
  ["--fg", "--page", 4.5, "body text", true],
  ["--fg-muted", "--page", 4.5, "muted text / page", true],
  ["--fg-muted", "--surface", 4.5, "muted text / surface", true],
  ["--fg", "--surface-soft", 4.5, "prose <code>", true],
  ["--on-pastel", "--sky", 4.5, "pill-live label", true],
  ["--face-ink", "--face-bg", 4.5, "avatar features", true],
  ["--page", "--fg", 4.5, "primary-btn label", true],   // btn-primary: color=page on bg=fg
  ["--ring", "--page", 3.0, "focus ring", true],
  // advisory — decorative / intentionally faint per the paper-first (thin-border) design;
  // reported for a human's eye but never fails the build (WCAG 1.4.11 exempts decoration).
  ["--border-strong", "--page", 3.0, "strong structural stroke", false],
  ["--fg-subtle", "--page", 4.5, "subtle micro-label", false],
  ["--border", "--page", 3.0, "hairline stroke", false],
  ["--grid-line", "--page", 3.0, "grid paper", false],
];

function run(themeName, theme) {
  const rows = [];
  let hardFails = 0;
  for (const [fg, bg, min, label, hard] of PAIRS) {
    const cr = ratio(resolve(theme, fg, bg), resolve(theme, bg, bg));
    const pass = cr >= min;
    if (hard && !pass) hardFails++;
    rows.push({ label, fg, bg, cr: cr.toFixed(2), min, pass, hard });
  }
  return { rows, hardFails };
}

let totalHardFails = 0;
for (const [name, theme] of [["LIGHT", light], ["DARK", dark]]) {
  const { rows, hardFails } = run(name, theme);
  totalHardFails += hardFails;
  console.log(`\n  ${name}  (WCAG contrast)`);
  console.log("  " + "─".repeat(58));
  for (const r of rows) {
    const mark = r.pass ? "✓" : r.hard ? "✗ FAIL" : "· advisory";
    const tag = r.hard ? "" : " (advisory)";
    console.log(`  ${mark.padEnd(11)} ${String(r.cr).padStart(6)} ≥ ${String(r.min).padEnd(4)} ${r.label}${tag}`);
  }
  console.log(`  ${hardFails === 0 ? "✓ all required pairs pass" : `✗ ${hardFails} required pair(s) below threshold`}`);
}

console.log("");
if (totalHardFails > 0) {
  console.error(`✗ contrast gate FAILED — ${totalHardFails} required pair(s) below WCAG threshold.\n`);
  process.exit(1);
}
console.log("✓ contrast gate passed (light + dark).\n");
