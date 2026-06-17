// catalog.js — generate the framework component workbook (catalog.html).
//
// ONE catalog of the whole work-* vocabulary, generated from the CEM (machine
// source of truth) + each element's source-header purpose, plus the new authoring
// vocabulary we design (status=planned). Never hand-drift the list — regenerate:
//   node tools/catalog.js
//
// The output is a single self-contained HTML workbook: it loads the built bundle
// (dist/workponents.js + dist/theme.css) so real elements upgrade live, and lists
// every element grouped by domain with purpose, status, attributes and a usage hint.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const cem = JSON.parse(readFileSync(join(ROOT, "custom-elements.json"), "utf8"));

// ── pull every custom element out of the CEM, tagging it with its domain (the
//    elements/<domain>/ path segment) and its source-header purpose. ────────────
const PURPOSE_RE = /^\/\/\s*<[a-z-]+>\s*[—-]?\s*(.*)$/m;
const built = [];
for (const m of cem.modules || []) {
  const domMatch = /elements\/([^/]+)\//.exec(m.path || "");
  const domain = domMatch ? domMatch[1] : "core";
  for (const d of m.declarations || []) {
    if (!d.customElement || !d.tagName) continue;
    let purpose = (d.summary || d.description || "").split("\n")[0].trim();
    if (!purpose) {
      const srcPath = join(ROOT, m.path);
      if (existsSync(srcPath)) {
        const hit = PURPOSE_RE.exec(readFileSync(srcPath, "utf8"));
        if (hit) purpose = hit[1].trim();
      }
    }
    built.push({
      tag: d.tagName,
      domain,
      status: "built",
      purpose: purpose || "—",
      attrs: (d.attributes || []).map((a) => a.name),
    });
  }
}

// ── THE SPINE: exactly three core elements (the Primitive Test result). Everything
//    else is a toolkit; "what something is" is an EDGE via work-ref (tagging = C). ──
const planned = [
  { tag: "work-src", purpose: "COMPUTE. Inline code in some lang, compiled by the Dock to a sandboxed WASM module. lang=rust|c|zig → native; lang=js|py → interpreted; lang=sql → data engine. name= exports a callable; display= runs & renders.", attrs: ["lang", "name", "display"] },
  { tag: "work-ref", purpose: "EVERY EDGE. Dependency, link, binding — AND type. rel= turns it into a reified type-assertion (rel=toolkit|skill|agent), so 'what something is' lives in the same graph as deps. Meaning comes from where it sits + rel.", attrs: ["to", "rel", "from", "as"] },
  { tag: "work-flow", purpose: "ORCHESTRATION. The runnable DAG the runtime schedules and runs — tasks + dependencies. A board/list/skill is just an authored VIEW or ordering over a flow. data-trigger triggers it (HTMX hx-trigger: load/every Ns/visible/event from:#id).", attrs: ["name", "data-trigger"] },
];
// work-src + work-ref are REAL elements now (in the CEM); work-flow too. Mark the spine
// "core" (built) and dedupe it from the toolkit groups below.
const SPINE = new Set(["work-src", "work-ref", "work-flow", "work-loop", "work-button"]);
for (const p of planned) { p.domain = "core · the spine"; p.status = "core"; }

// ── domain → visual-toolkit prefix (the re-prefix plan). Each domain becomes its own
//    toolkit owning <prefix-*> elements; work- retracts to the spine above. ──
const TOOLKIT = {
  "data-viz": "chart", tables: "grid", records: "record", ai: "chat",
  presentation: "deck", pm: "board", docs: "document", maps: "map",
  forms: "form", video: "video", code: "code", files: "file",
  git: "git", live: "live", search: "search", auth: "auth", "3d": "model",
  flow: "flow", data: "data", core: "work",
};
const builtToolkits = built.filter((e) => !SPINE.has(e.tag));   // spine shown in its own group
for (const e of builtToolkits) {
  const tk = TOOLKIT[e.domain] || e.domain;
  e.current = e.tag;                                   // keep the old name for reference
  let base = e.tag.replace(/^work-/, "").replace(/^(doc|model)-/, "");
  base = base.replace(new RegExp("^" + tk + "-"), "");           // de-dupe: record-list → list
  e.tag = (base === "" || base === tk || ["doc", "model"].includes(base)) ? tk : `${tk}-${base}`;
  e.domain = tk;
}

// ── group by domain; authoring first (it's the spine), then the rest A→Z. ──────
const all = [...planned, ...builtToolkits];
const groups = {};
for (const e of all) (groups[e.domain] ||= []).push(e);
const order = ["core · the spine", ...Object.keys(groups).filter((d) => d !== "core · the spine").sort()];

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const usage = (e) =>
  e.attrs.length
    ? `<${e.tag} ${e.attrs.slice(0, 3).map((a) => `${a}="…"`).join(" ")}></${e.tag}>`
    : `<${e.tag}></${e.tag}>`;

const card = (e) => `
    <article class="card ${e.status}">
      <header><code class="tag">&lt;${esc(e.tag)}&gt;</code><span class="badge ${e.status}">${e.status === "core" ? "core" : "toolkit"}</span></header>
      ${e.current && e.current !== e.tag ? `<p class="was">was <code>&lt;${esc(e.current)}&gt;</code></p>` : ""}
      <p class="purpose">${esc(e.purpose)}</p>
      ${e.attrs.length ? `<p class="attrs">${e.attrs.map((a) => `<span>${esc(a)}</span>`).join("")}</p>` : ""}
      <pre class="usage"><code>${esc(usage(e))}</code></pre>
    </article>`;

const section = (dom) => `
  <section id="${esc(dom.replace(/[^a-z]+/gi, "-"))}">
    <h2>${esc(dom)} <span class="count">${groups[dom].length}</span></h2>
    <div class="grid">${groups[dom].sort((a, b) => a.tag.localeCompare(b.tag)).map(card).join("")}</div>
  </section>`;

const nav = order
  .map((d) => `<a href="#${esc(d.replace(/[^a-z]+/gi, "-"))}">${esc(d)} <em>${groups[d].length}</em></a>`)
  .join("");

const html = `<!doctype html>
<html lang="en" data-theme="paper">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="darkreader-lock"><meta name="color-scheme" content="light dark">
<title>work-* — the framework catalog</title>
<link rel="stylesheet" href="dist/theme.css">
<script type="module" src="dist/workponents.js"></script>
<style>
  :root { --ink:#121316; --paper:#f7f6f1; --card:#fbfaf3; --line:#e4e1d6; --mut:#6b6a63;
          --mint:#aee5c2; --sky:#a8d4f0; --peach:#f3c5a3; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--paper); color:var(--ink);
         font:15px/1.5 "Geist", ui-sans-serif, system-ui, sans-serif; }
  code, pre, .tag { font-family:"Geist Mono", ui-monospace, "SF Mono", monospace; }
  .wrap { display:grid; grid-template-columns:230px 1fr; gap:0; align-items:start; }
  nav { position:sticky; top:0; height:100vh; overflow:auto; padding:24px 16px;
        border-right:1px solid var(--line); background:var(--card); }
  nav h1 { font-size:15px; margin:0 0 14px; letter-spacing:-.01em; }
  nav h1 b { background:var(--ink); color:var(--paper); padding:2px 7px; border-radius:6px; }
  nav a { display:flex; justify-content:space-between; gap:8px; padding:5px 8px; margin:1px 0;
          color:var(--ink); text-decoration:none; border-radius:7px; font-size:13px; }
  nav a:hover { background:var(--paper); }
  nav a em { color:var(--mut); font-style:normal; }
  main { padding:36px 44px 120px; max-width:1240px; }
  .lead { color:var(--mut); margin:0 0 48px; max-width:64ch; line-height:1.65; }
  .lead b { color:var(--ink); }
  section { margin:0 0 72px; scroll-margin-top:18px; }
  section + section { padding-top:8px; }
  section h2 { font-size:13px; text-transform:uppercase; letter-spacing:.12em; color:var(--mut);
               border-bottom:2px solid var(--ink); padding-bottom:12px; margin:0 0 28px; }
  section h2 .count { float:right; color:var(--ink); background:var(--paper);
                      border:1px solid var(--line); border-radius:20px; padding:1px 11px; font-size:12px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(400px,1fr)); gap:22px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:20px 22px;
          box-shadow:0 1px 0 rgba(18,19,22,.03), 0 8px 22px -16px rgba(18,19,22,.25); }
  .card.core { border-style:dashed; }
  .card header { display:flex; align-items:center; justify-content:space-between; gap:8px; margin-bottom:10px; }
  .tag { font-size:14px; font-weight:600; }
  .badge { font-size:10px; text-transform:uppercase; letter-spacing:.06em; padding:2px 7px; border-radius:20px; }
  .badge.built { background:var(--mint); color:#0c3a22; }
  .badge.core { background:var(--peach); color:#5a2c10; }
  .was { margin:0 0 7px; font:11px/1 "Geist Mono",monospace; color:var(--mut); }
  .was code { background:#0000000a; padding:1px 5px; border-radius:5px; }
  .purpose { margin:0 0 13px; font-size:14px; line-height:1.55; color:#2a2b2f; }
  .attrs { margin:0 0 13px; display:flex; flex-wrap:wrap; gap:6px; }
  .attrs span { font:11px/1 "Geist Mono",monospace; background:var(--sky); color:#0d3450;
                padding:4px 7px; border-radius:5px; }
  .usage { margin:0; background:var(--ink); color:#e9e8e2; border-radius:9px; padding:12px 14px;
           white-space:pre-wrap; word-break:break-word; overflow:visible; font-size:12px; line-height:1.6; }
  .usage code { color:#e9e8e2; white-space:inherit; word-break:inherit; }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <h1><b>work-*</b> catalog</h1>
    ${nav}
  </nav>
  <main>
    <p class="lead"><b>The spine is ${planned.length} real elements</b> — <code>work-src</code>
    (compute), <code>work-ref</code> (every edge, incl. type via <code>rel=</code>),
    <code>work-flow</code> (the DAG). Everything else is a <b>toolkit</b>: ${builtToolkits.length}
    built elements regrouped into <b>${order.length - 1} visual toolkits</b>, each owning its
    own <code>&lt;prefix-*&gt;</code> (work-table → <code>grid-table</code>). "What something
    is" is an edge, not an element — there's no <code>&lt;work-toolkit&gt;</code>. Generated
    from the CEM — <code>node tools/catalog.js</code>.</p>
    ${order.map(section).join("")}
  </main>
</div>
</body>
</html>`;

writeFileSync(join(ROOT, "catalog.html"), html);
console.log(`catalog.html — ${all.length} elements (${planned.length} core spine, ${builtToolkits.length} toolkit) in ${order.length} groups`);
