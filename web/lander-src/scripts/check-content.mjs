#!/usr/bin/env node
// check-content.mjs — validate the runtime content tree before deploy.
//
// The page loads agent-authored sections + blog posts at RUNTIME from manifests
// (no build step), so the manifests and the files on disk must stay in lockstep.
// This catches the two failure modes that "appears on next load" makes silent:
//   - a file written but no manifest row  → it never shows ("forgot to add it")
//   - a manifest row with no file         → a fetch 404s (silent gap)
//
// No dependencies. Run from web/lander-src:  node scripts/check-content.mjs
// Optional arg: a content root (defaults to ./public/content).
//
// Exits non-zero with one clear message per problem.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
// content lives under public/ (Vite copies it verbatim into dist/)
const root = resolve(process.argv[2] || join(here, '..', 'public', 'content'));

const problems = [];
const fail = (msg) => problems.push(msg);

const readJson = (path) => {
  if (!existsSync(path)) return null;            // absent manifest is valid (empty site)
  try { return JSON.parse(readFileSync(path, 'utf8')); }
  catch (e) { fail(`${path}: invalid JSON — ${e.message}`); return undefined; }
};

const listHtml = (dir) =>
  existsSync(dir) && statSync(dir).isDirectory()
    ? readdirSync(dir).filter((f) => f.endsWith('.html'))
    : [];

// ── sections.json ↔ content/sections/*.html ──────────────────────────
const sectionsManifest = readJson(join(root, 'sections.json'));
const sectionFiles = listHtml(join(root, 'sections'));

if (Array.isArray(sectionsManifest)) {
  const seenOrders = new Map();
  const referenced = new Set();
  let lastPinSeen = false;

  sectionsManifest.forEach((e, i) => {
    const at = `sections.json[${i}]`;
    if (typeof e.slug !== 'string' || !e.slug) fail(`${at}: missing "slug"`);
    if (typeof e.file !== 'string' || !e.file) fail(`${at}: missing "file"`);
    if (typeof e.order !== 'number') fail(`${at}: "order" must be a number`);

    // no duplicate orders
    if (typeof e.order === 'number') {
      if (seenOrders.has(e.order))
        fail(`${at}: duplicate order ${e.order} (also at sections.json[${seenOrders.get(e.order)}])`);
      else seenOrders.set(e.order, i);
    }

    // the file must exist (manifest paths are relative to the site root,
    // e.g. "content/sections/04-the-workbook.html")
    if (e.file) {
      const filePath = resolve(root, '..', e.file);
      referenced.add(basename(e.file));
      if (!existsSync(filePath)) fail(`${at}: file not found — ${e.file}`);
      else validateSectionPartial(filePath, at);
    }

    // faq pinned last: a pin:"last" entry must not be followed by an un-pinned one
    if (e.pin === 'last') lastPinSeen = true;
    else if (lastPinSeen) fail(`${at}: un-pinned entry follows a pin:"last" entry — pinned entries must sort last`);

    // an faq slug should carry pin:"last"
    if (/faq/i.test(e.slug || '') && e.pin !== 'last')
      fail(`${at}: slug "${e.slug}" looks like an faq but is not pinned ("pin":"last")`);
  });

  // orphans: a partial on disk with no manifest row
  for (const f of sectionFiles)
    if (!referenced.has(f))
      fail(`content/sections/${f}: file exists but has no sections.json entry (orphan)`);
}

function validateSectionPartial(filePath, at) {
  const html = readFileSync(filePath, 'utf8');
  const secs = html.match(/<section\b[^>]*class=["'][^"']*\bgrown\b[^"']*["'][^>]*>/gi) || [];
  if (secs.length !== 1)
    fail(`${at}: partial must contain exactly one <section class="grown"> (found ${secs.length})`);
  if (!/<h2\b[^>]*>/i.test(html))
    fail(`${at}: partial is missing an <h2>`);
}

// ── blog.json ↔ blog/*.html ──────────────────────────────────────────
// blog partials live in public/blog/ (shipped to dist/blog/); validate the
// manifest ↔ file pairing the same way. Skip silently if neither exists.
const blogManifest = readJson(join(root, 'blog.json'));
const blogDir = resolve(root, '..', 'blog');
const blogFiles = listHtml(blogDir);

if (Array.isArray(blogManifest)) {
  const referenced = new Set();
  blogManifest.forEach((e, i) => {
    const at = `blog.json[${i}]`;
    if (typeof e.slug !== 'string' || !e.slug) fail(`${at}: missing "slug"`);
    if (typeof e.file !== 'string' || !e.file) fail(`${at}: missing "file"`);
    if (e.file) {
      referenced.add(basename(e.file));
      const filePath = resolve(root, '..', e.file);
      if (!existsSync(filePath)) fail(`${at}: file not found — ${e.file}`);
    }
  });
  for (const f of blogFiles)
    if (!referenced.has(f))
      fail(`blog/${f}: file exists but has no blog.json entry (orphan)`);
}

// ── report ────────────────────────────────────────────────────────────
if (problems.length) {
  console.error(`content check FAILED — ${problems.length} problem(s):\n`);
  for (const p of problems) console.error('  ✗ ' + p);
  console.error('');
  process.exit(1);
}
console.log('content check OK — manifests and files are in sync.');
