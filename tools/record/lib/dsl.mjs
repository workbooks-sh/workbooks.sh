// dsl — the org-mode demo timeline parser. ONE `.org` file = one demo, and the
// single source of truth for BOTH the driver (what to do, when) and the
// voiceover (what to say, when). Frames are the canonical clock (see timecode).
//
// Header keywords (file top, `#+KEY: value`):
//   #+TITLE:    demo title (-> recipe name)
//   #+TARGET:   web | app                         (default web)
//   #+URL:      default navigate URL
//   #+FPS:      frames per second                 (default 30)
//   #+VIEWPORT: WIDTHxHEIGHT                       (default 1440x900)
//   #+VERIFY_FRAMES: N                             (optional; verifier sample count)
//
// Each `*` headline is a CUE:
//   * <timecode> <intent> [key:val] [key:val]...
//     narration line one
//     narration line two
//     :PROPERTIES:
//     :selector: button.search
//     :url: http://localhost:5178/
//     :END:
//
// - <timecode> is any form timecode.mjs accepts (SS, MM:SS, HH:MM:SS, HH:MM:SS:FF, fN).
// - <intent> is one of the intent kinds (navigate/click/type/hover/wait/screenshot/eval_js/dom_read).
// - Inline `[key:val]` args and a `:PROPERTIES:` drawer both populate `args`;
//   the drawer wins on conflict. Recognized arg keys: selector, url, x, y, text,
//   ms, code, name, checkpoint, waituntil, perkeyms, timeoutms.
// - Body lines that are NOT a drawer / not the headline become the NARRATION
//   spoken starting at that cue's frame.
//
// Output:
//   { title, target, url, fps, viewport:{width,height}, verifyFrames,
//     cues: [ { frame, tcode, intent, args, narration } ] }
//
// Validation: cues are sorted ascending by frame (we sort + warn if input was
// out of order). Narration-overlap warnings need TTS clip durations, so those
// are emitted later by the voiceover stage (see voiceover.mjs).

import fs from "node:fs/promises";
import { toFrames } from "./timecode.mjs";

// keys that carry a numeric value
const NUM_KEYS = new Set(["x", "y", "ms", "perkeyms", "timeoutms", "verifyframes"]);
// drawer/inline key -> canonical arg name on the step
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
  waituntil: "waitUntil",
  perkeyms: "perKeyMs",
  timeoutms: "timeoutMs",
};

const INTENTS = new Set([
  "navigate", "click", "rightclick", "type", "hover", "move", "drag",
  "wait", "screenshot", "eval_js", "dom_read",
]);

function coerce(key, raw) {
  const v = raw.trim();
  if (NUM_KEYS.has(key)) {
    const n = Number(v);
    return Number.isFinite(n) ? n : v;
  }
  return v;
}

// Pull `[key:val]` tokens out of a headline tail. Values may contain spaces if
// the author avoids `]`; for selectors/text with `]`, use the PROPERTIES drawer.
function parseInlineArgs(tail) {
  const args = {};
  let rest = tail;
  const re = /\[([a-zA-Z_]+)\s*:\s*([^\]]*)\]/g;
  let m;
  while ((m = re.exec(tail))) {
    const key = m[1].toLowerCase();
    const canon = KEY_ALIAS[key];
    if (canon) args[canon] = coerce(key, m[2]);
  }
  rest = tail.replace(re, "").trim();
  return { args, leftover: rest };
}

export function parseOrg(text) {
  const lines = text.split(/\r?\n/);
  const header = {};
  const cues = [];
  const warnings = [];

  let i = 0;
  // ---- header keywords (any `#+KEY: value` lines before/among blank lines) ----
  for (; i < lines.length; i++) {
    const l = lines[i];
    if (/^\s*\*/.test(l)) break; // first headline -> cues begin
    const hm = /^\s*#\+([A-Za-z_]+):\s*(.*)$/.exec(l);
    if (hm) header[hm[1].toUpperCase()] = hm[2].trim();
  }

  const fps = header.FPS ? Number(header.FPS) : 30;
  if (!Number.isFinite(fps) || fps <= 0) throw new Error(`dsl: bad #+FPS: ${header.FPS}`);

  let vp = { width: 1440, height: 900 };
  if (header.VIEWPORT) {
    const vm = /^(\d+)\s*[xX]\s*(\d+)$/.exec(header.VIEWPORT.trim());
    if (vm) vp = { width: +vm[1], height: +vm[2] };
    else warnings.push(`bad #+VIEWPORT: ${header.VIEWPORT} (using ${vp.width}x${vp.height})`);
  }

  // ---- cue headlines ----
  for (; i < lines.length; i++) {
    const l = lines[i];
    const hm = /^\s*\*+\s+(.*)$/.exec(l);
    if (!hm) continue; // stray top-level line between cues — ignore
    const headTail = hm[1].trim();
    // <timecode> <intent> <rest...>
    const parts = headTail.split(/\s+/);
    const tcode = parts.shift();
    const intent = (parts.shift() || "").toLowerCase();
    if (!INTENTS.has(intent)) {
      throw new Error(`dsl: cue "${headTail}" has unknown intent "${intent}" (have: ${[...INTENTS].join(", ")})`);
    }
    const { args } = parseInlineArgs(parts.join(" "));

    // ---- collect body: narration lines + optional PROPERTIES drawer ----
    const narrationLines = [];
    let j = i + 1;
    for (; j < lines.length; j++) {
      const b = lines[j];
      if (/^\s*\*+\s+/.test(b)) break; // next headline
      if (/^\s*:PROPERTIES:\s*$/i.test(b)) {
        // consume drawer until :END:
        j++;
        for (; j < lines.length; j++) {
          const d = lines[j];
          if (/^\s*:END:\s*$/i.test(d)) break;
          const dm = /^\s*:([A-Za-z_]+):\s*(.*)$/.exec(d);
          if (dm) {
            const key = dm[1].toLowerCase();
            const canon = KEY_ALIAS[key];
            if (canon) args[canon] = coerce(key, dm[2]); // drawer wins
          }
        }
        continue;
      }
      const trimmed = b.trim();
      if (trimmed === "") {
        // a blank line inside a cue body is a soft separator; keep paragraphs together
        if (narrationLines.length && narrationLines[narrationLines.length - 1] !== "") narrationLines.push("");
        continue;
      }
      if (/^#\+/.test(trimmed)) continue; // stray keyword in body
      narrationLines.push(trimmed);
    }
    i = j - 1; // resume at the line before the next headline

    const narration = narrationLines.join(" ").replace(/\s+/g, " ").trim();
    const frame = toFrames(tcode, fps);
    cues.push({ frame, tcode, intent, args, narration });
  }

  // ---- validate ordering ----
  const sorted = [...cues].sort((a, b) => a.frame - b.frame);
  for (let k = 0; k < cues.length; k++) {
    if (cues[k].frame !== sorted[k].frame) {
      warnings.push("cues were not in ascending frame order — sorted them");
      break;
    }
  }

  return {
    title: header.TITLE || "Untitled demo",
    target: (header.TARGET || "web").toLowerCase(),
    url: header.URL || null,
    fps,
    viewport: vp,
    verifyFrames: header.VERIFY_FRAMES ? Number(header.VERIFY_FRAMES) : undefined,
    cues: sorted,
    warnings,
  };
}

export async function loadOrg(p) {
  return parseOrg(await fs.readFile(p, "utf8"));
}

// Project an org demo onto the existing recipe shape so the rest of the harness
// (verify expected-lines, slug, voiceover.lines fallback) keeps working. The
// per-cue frame schedule lives in `__cues`; the driver consumes it directly.
export function orgToRecipe(demo) {
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
    __cues: demo.cues, // frame-accurate schedule, source of truth
  };
}

// Run directly: `node lib/dsl.mjs demo.org` -> prints parsed JSON + warnings.
if (import.meta.url === `file://${process.argv[1]}`) {
  const p = process.argv[2];
  if (!p) {
    console.error("usage: dsl.mjs <demo.org>");
    process.exit(2);
  }
  loadOrg(p).then((d) => {
    for (const w of d.warnings) process.stderr.write(`warn: ${w}\n`);
    process.stdout.write(JSON.stringify(d, null, 2) + "\n");
  });
}
