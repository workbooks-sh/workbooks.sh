#!/usr/bin/env node
// build-timeline — synthesize the EDIT-STATE TIMELINE a nexus agent produces
// while authoring a workbook, then write the inputs the `wavelet film` lane eats.
//
// This is the deterministic stand-in for what a REAL in-nexus agent already has:
// after every edit it makes to the workbook, the current HTML is the workbook's
// own state, and the step label is the agent's own description of that edit
// (exactly the `tool`/`args` line it appends to `_steps.jsonl`). Here we author a
// kanban workbook across four real edits — empty -> title -> sections -> content —
// capturing the workbook HTML snapshot + a label AFTER EACH edit.
//
// Output (into --out DIR, default this file's dir):
//   timeline.json     — ordered [{snapshot_file,label,hold_secs}, ...] for wavelet film
//   step-N.html       — the workbook HTML at edit state N (the snapshot)
//   expected.txt      — the steps the demo must show (gates the vision verifier)
//   narration.json    — { lines:[...] } one narration line per edit (for TTS)
//
// No network, no runtime — pure file emit. Run: node build-timeline.mjs [--out DIR]

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// ── workbook skin (brand canon: live-green #3fe081, Geist, low chrome) ──────────
// A snapshot is a STATE: the film lane paints each at the animation clock t=0, so
// the HTML must look right STATICALLY (no JS, no entrance animation needed).
function page(bodyInner, { titled = false } = {}) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<style>
  :root{--bg:#0b0f0d;--panel:#111714;--line:#1d2a23;--ink:#e8f3ec;--mut:#7f9a8c;--green:#3fe081;--greend:#149157}
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%}
  body{background:radial-gradient(120% 120% at 50% -10%,#0e1512 0%,#0b0f0d 60%);color:var(--ink);
       font-family:'Geist','Inter',system-ui,sans-serif;-webkit-font-smoothing:antialiased}
  .app{height:100%;display:flex;flex-direction:column}
  .bar{display:flex;align-items:center;gap:10px;padding:14px 22px;border-bottom:1px solid var(--line);background:rgba(17,23,20,.6)}
  .dot{width:10px;height:10px;border-radius:50%;background:var(--green);box-shadow:0 0 12px var(--green)}
  .wb-name{font-size:13px;letter-spacing:.04em;color:var(--mut);font-weight:600}
  .wb-name b{color:${titled ? "var(--ink)" : "var(--mut)"};font-weight:700}
  .canvas{flex:1;overflow:hidden;padding:34px 40px}
  .empty{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;color:var(--mut)}
  .empty .glyph{width:54px;height:54px;border:2px dashed var(--line);border-radius:14px;display:flex;align-items:center;justify-content:center;font-size:26px;color:var(--line)}
  h1{font-size:34px;font-weight:800;letter-spacing:-.02em;margin-bottom:6px}
  .dek{color:var(--mut);font-size:15px;margin-bottom:26px}
  .board{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;height:calc(100% - 90px)}
  .col{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px;display:flex;flex-direction:column;gap:10px;min-height:0}
  .col h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);display:flex;align-items:center;gap:8px}
  .col h2 .pip{width:7px;height:7px;border-radius:50%;background:var(--green)}
  .col.todo h2 .pip{background:#5b6b62}
  .col.doing h2 .pip{background:var(--green)}
  .col.done h2 .pip{background:var(--greend)}
  .card{background:#0d1411;border:1px solid var(--line);border-left:3px solid var(--green);border-radius:9px;padding:11px 12px;font-size:13px;line-height:1.35}
  .card .tag{display:inline-block;margin-top:7px;font-size:10px;color:var(--green);border:1px solid var(--greend);border-radius:999px;padding:1px 8px}
  .card.muted{border-left-color:#3a4a42;opacity:.65}
  .ph{height:34px;border:1px dashed var(--line);border-radius:9px}
</style></head>
<body><div class="app">
  <div class="bar"><span class="dot"></span><span class="wb-name">workbook · <b>${titled ? "Launch Board" : "untitled"}</b></span></div>
  <div class="canvas">${bodyInner}</div>
</div></body></html>`;
}

// edit state 0 — empty workbook (nothing authored yet)
const STEP_EMPTY = page(
  `<div class="empty"><div class="glyph">+</div><div>empty workbook — start authoring</div></div>`
);

// edit state 1 — title added
const STEP_TITLE = page(
  `<h1>Launch Board</h1><div class="dek">Track the v1 launch from idea to shipped.</div>`,
  { titled: true }
);

// edit state 2 — three kanban sections added (still empty)
const STEP_SECTIONS = page(
  `<h1>Launch Board</h1><div class="dek">Track the v1 launch from idea to shipped.</div>
   <div class="board">
     <div class="col todo"><h2><span class="pip"></span>To do</h2><div class="ph"></div><div class="ph"></div></div>
     <div class="col doing"><h2><span class="pip"></span>In progress</h2><div class="ph"></div></div>
     <div class="col done"><h2><span class="pip"></span>Done</h2><div class="ph"></div></div>
   </div>`,
  { titled: true }
);

// edit state 3 — content filled into the sections
const STEP_CONTENT = page(
  `<h1>Launch Board</h1><div class="dek">Track the v1 launch from idea to shipped.</div>
   <div class="board">
     <div class="col todo"><h2><span class="pip"></span>To do</h2>
       <div class="card">Write the pricing page<span class="tag">copy</span></div>
       <div class="card">Set up analytics events<span class="tag">data</span></div>
     </div>
     <div class="col doing"><h2><span class="pip"></span>In progress</h2>
       <div class="card">Build the onboarding flow<span class="tag">app</span></div>
     </div>
     <div class="col done"><h2><span class="pip"></span>Done</h2>
       <div class="card muted">Domain + DNS live<span class="tag">infra</span></div>
       <div class="card muted">Brand palette locked<span class="tag">design</span></div>
     </div>
   </div>`,
  { titled: true }
);

// The ordered timeline — one entry per EDIT the agent made. label + hold + the
// snapshot HTML file. (snapshot_file, not inline, so the staged dir mirrors how a
// real agent keeps each state as a file beside its run.)
const STEPS = [
  { file: "step-0.html", html: STEP_EMPTY,    label: "Empty workbook",                       hold_secs: 1.8,
    narration: "We start with a brand new, empty workbook." },
  { file: "step-1.html", html: STEP_TITLE,    label: "Add the title — Launch Board",         hold_secs: 2.2,
    narration: "First, the agent gives it a title: Launch Board." },
  { file: "step-2.html", html: STEP_SECTIONS, label: "Add three sections: To do, In progress, Done", hold_secs: 2.4,
    narration: "Next, it lays out three kanban sections: to do, in progress, and done." },
  { file: "step-3.html", html: STEP_CONTENT,  label: "Fill the sections with launch tasks",  hold_secs: 3.0,
    narration: "Finally, it fills each section with the real launch tasks. The workbook is done." },
];

function parseOut(argv) {
  for (let i = 0; i < argv.length; i++) if (argv[i] === "--out") return argv[i + 1];
  return HERE;
}

async function main() {
  const out = path.resolve(parseOut(process.argv.slice(2)));
  await fs.mkdir(out, { recursive: true });

  for (const s of STEPS) await fs.writeFile(path.join(out, s.file), s.html);

  const timeline = STEPS.map((s) => ({ snapshot_file: s.file, label: s.label, hold_secs: s.hold_secs }));
  await fs.writeFile(path.join(out, "timeline.json"), JSON.stringify(timeline, null, 2));

  const expected = STEPS.map((s, i) => `${i + 1}. ${s.label}`).join("\n");
  await fs.writeFile(
    path.join(out, "expected.txt"),
    "A screen recording of an agent authoring a kanban workbook, edit by edit:\n" +
      expected +
      "\nEach state shows the workbook UI (dark theme, green accents) with an on-screen caption naming the edit.\n"
  );

  await fs.writeFile(
    path.join(out, "narration.json"),
    JSON.stringify({ lines: STEPS.map((s) => s.narration) }, null, 2)
  );

  console.log(JSON.stringify({ out, steps: STEPS.length, files: STEPS.map((s) => s.file) }, null, 2));
}

main().catch((e) => {
  console.error("build-timeline fatal:", e);
  process.exit(1);
});
