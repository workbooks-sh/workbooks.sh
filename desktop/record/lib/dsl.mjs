// dsl — the `.work` demo-timeline parser. ONE `.work` file = one demo, and the
// single source of truth for BOTH the driver (what to do, when) and the
// voiceover (what to say, when). Frames are the canonical clock (see timecode).
//
// This is the work-aligned successor to the old `.org` timeline (struck with the
// rest of the org-mode lane). It follows workbook canon: prose narrates, and the
// first word of a block names its KIND (`demo`, `cue`). A block is self-delimiting
// (`kind … do … end`); the body carries narration (prose) + typed `key: value`
// lines (the action's selector/checkpoint/etc).
//
//   demo :product-showcase do
//     title: Workbooks — product showcase
//     target: web
//     url: http://localhost:5178/
//     fps: 30
//     viewport: 1440x900
//     verify_frames: 16
//   end
//
//   cue "00:02", :click do
//     Four real businesses live here — switch from one menu.
//     selector: button[aria-label^="Switch workspace"]
//     checkpoint: the workspace switcher menu is open
//   end
//
// Cue header: `cue "<timecode>", :<intent> do`
//   - <timecode> — any form timecode.mjs accepts (SS, MM:SS, HH:MM:SS, HH:MM:SS:FF, fN).
//   - <intent>   — one of the intent kinds below.
// Cue body lines:
//   - `key: value` where key is a recognized action key → an arg. The value is
//     RAW to end-of-line (so selectors/JS with any `:` `]` `"` survive verbatim).
//   - any other non-empty prose line → narration spoken from this cue's frame.
//
// Output (identical shape to what the driver/voiceover already consume):
//   { title, target, url, fps, viewport:{width,height}, verifyFrames,
//     cues: [ { frame, tcode, intent, args, narration } ], warnings }

import fs from "node:fs/promises";
import { toFrames } from "./timecode.mjs";

// recognized cue-body action keys → canonical arg name on the step. A body line
// `key: value` is an arg ONLY if key is here; otherwise the line is narration
// (so "Workbooks: every workspace." stays prose, never a mis-parsed arg).
const KEY_ALIAS = {
  selector: "selector",
  to: "to",
  url: "url",
  x: "x",
  y: "y",
  text: "text",
  ms: "ms",
  code: "code",
  name: "name",
  checkpoint: "checkpoint",
  wait_until: "waitUntil",
  waituntil: "waitUntil",
  per_key_ms: "perKeyMs",
  perkeyms: "perKeyMs",
  timeout_ms: "timeoutMs",
  timeoutms: "timeoutMs",
};
// keys that carry a numeric value
const NUM_KEYS = new Set(["x", "y", "ms", "perKeyMs", "timeoutMs"]);
// demo-header keys (live in the `demo … do … end` block body)
const HEADER_KEYS = new Set(["title", "target", "url", "fps", "viewport", "verify_frames"]);

const INTENTS = new Set([
  "navigate", "click", "rightclick", "type", "hover", "move", "drag",
  "wait", "screenshot", "eval_js", "dom_read",
]);

function coerce(canonKey, raw) {
  const v = raw.trim();
  if (NUM_KEYS.has(canonKey)) {
    const n = Number(v);
    return Number.isFinite(n) ? n : v;
  }
  return v;
}

// Collect a block body: the lines between an opening `… do` and its matching
// `end`. Demo timelines are flat (no nested blocks), so the first `end` closes it.
function takeBlock(lines, start) {
  const body = [];
  let i = start + 1;
  for (; i < lines.length; i++) {
    if (/^\s*end\s*$/.test(lines[i])) break;
    body.push(lines[i]);
  }
  return { body, end: i };
}

export function parseWork(text) {
  const lines = text.split(/\r?\n/);
  const header = {};
  const cues = [];
  const warnings = [];
  let titleFromHeading = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // a markdown-style `# Heading` is a friendly title fallback
    const hh = /^\s*#\s+(.+?)\s*$/.exec(line);
    if (hh && !titleFromHeading) titleFromHeading = hh[1].trim();

    // ── demo header block ──────────────────────────────────────────────
    if (/^\s*demo\b.*\bdo\s*$/.test(line)) {
      const { body, end } = takeBlock(lines, i);
      for (const b of body) {
        const km = /^\s*([a-z_]+):\s*(.*)$/i.exec(b);
        if (km && HEADER_KEYS.has(km[1].toLowerCase())) header[km[1].toLowerCase()] = km[2].trim();
      }
      i = end;
      continue;
    }

    // ── cue block:  cue "<tc>", :<intent> do ───────────────────────────
    const cm = /^\s*cue\s+"([^"]+)"\s*,\s*:([a-z_]+)\s+do\s*$/i.exec(line);
    if (cm) {
      const tcode = cm[1].trim();
      const intent = cm[2].toLowerCase();
      if (!INTENTS.has(intent)) {
        throw new Error(`dsl: cue @${tcode} has unknown intent "${intent}" (have: ${[...INTENTS].join(", ")})`);
      }
      const { body, end } = takeBlock(lines, i);
      const args = {};
      const narrationLines = [];
      for (const b of body) {
        const trimmed = b.trim();
        if (trimmed === "") continue;
        const km = /^([a-z_]+):\s*(.*)$/i.exec(trimmed);
        const canon = km && KEY_ALIAS[km[1].toLowerCase()];
        if (canon) args[canon] = coerce(canon, km[2]);
        else narrationLines.push(trimmed);
      }
      const narration = narrationLines.join(" ").replace(/\s+/g, " ").trim();
      cues.push({ frame: 0, tcode, intent, args, narration }); // frame filled once fps known
      i = end;
      continue;
    }
  }

  const fps = header.fps ? Number(header.fps) : 30;
  if (!Number.isFinite(fps) || fps <= 0) throw new Error(`dsl: bad fps: ${header.fps}`);

  let vp = { width: 1440, height: 900 };
  if (header.viewport) {
    const vm = /^(\d+)\s*[xX]\s*(\d+)$/.exec(header.viewport.trim());
    if (vm) vp = { width: +vm[1], height: +vm[2] };
    else warnings.push(`bad viewport: ${header.viewport} (using ${vp.width}x${vp.height})`);
  }

  for (const c of cues) c.frame = toFrames(c.tcode, fps);

  const sorted = [...cues].sort((a, b) => a.frame - b.frame);
  for (let k = 0; k < cues.length; k++) {
    if (cues[k].frame !== sorted[k].frame) {
      warnings.push("cues were not in ascending frame order — sorted them");
      break;
    }
  }

  return {
    title: header.title || titleFromHeading || "Untitled demo",
    target: (header.target || "web").toLowerCase(),
    url: header.url || null,
    fps,
    viewport: vp,
    verifyFrames: header.verify_frames ? Number(header.verify_frames) : undefined,
    cues: sorted,
    warnings,
  };
}

export async function loadWork(p) {
  return parseWork(await fs.readFile(p, "utf8"));
}

// Project a demo onto the recipe shape the rest of the harness consumes. The
// per-cue frame schedule lives in `__cues`; the driver paces against it.
export function demoToRecipe(demo) {
  const steps = demo.cues.map((c) => {
    const step = { intent: c.intent, ...c.args };
    if (c.intent === "navigate" && !step.url && demo.url) step.url = demo.url;
    step.label = c.narration || c.intent;
    return step;
  });
  return {
    name: demo.title,
    target: demo.target,
    viewport: demo.viewport,
    fps: demo.fps,
    verifyFrames: demo.verifyFrames,
    voiceover: { lines: demo.cues.map((c) => c.narration).filter(Boolean) },
    steps,
    __cues: demo.cues,
  };
}

// Run directly: `node lib/dsl.mjs demo.work` -> prints parsed JSON + warnings.
if (import.meta.url === `file://${process.argv[1]}`) {
  const p = process.argv[2];
  if (!p) {
    console.error("usage: dsl.mjs <demo.work>");
    process.exit(2);
  }
  loadWork(p).then((d) => {
    for (const w of d.warnings) process.stderr.write(`warn: ${w}\n`);
    process.stdout.write(JSON.stringify(d, null, 2) + "\n");
  });
}
