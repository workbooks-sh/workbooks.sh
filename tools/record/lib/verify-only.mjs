#!/usr/bin/env node
// verify-only — run the proof-loop VERIFY cascade against an already-captured
// video + an expected-steps string, independent of the driver. The pipeline
// orchestrator (tools/record/pipeline) uses this to gate the REAL MP4 produced
// by the Linux capture rig, instead of the still-strip slideshow record.mjs
// builds when no recorder is present.
//
//   node lib/verify-only.mjs --video out/take.mp4 \
//        --expected-file out/take.expected.txt \
//        [--signals-file out/take.signals.json] [--frames N]
//
// Prints the verdict JSON on stdout; exit 0 = pass (or skipped — no key), 1 = fail.
// Same cascade + key resolution as the inline path, so there's ONE verifier.

import fs from "node:fs/promises";
import { verifyRecording } from "./verify.mjs";

function parse(argv) {
  const a = { frames: undefined };
  for (let i = 0; i < argv.length; i++) {
    const x = argv[i];
    if (x === "--video") a.video = argv[++i];
    else if (x === "--expected-file") a.expectedFile = argv[++i];
    else if (x === "--expected") a.expected = argv[++i];
    else if (x === "--signals-file") a.signalsFile = argv[++i];
    else if (x === "--frames") a.frames = +argv[++i];
  }
  return a;
}

async function readMaybe(p, dflt) {
  if (!p) return dflt;
  try {
    return await fs.readFile(p, "utf8");
  } catch {
    return dflt;
  }
}

async function main() {
  const a = parse(process.argv.slice(2));
  if (!a.video) {
    console.error("usage: verify-only.mjs --video FILE [--expected-file F | --expected S] [--signals-file F] [--frames N]");
    process.exit(2);
  }
  try {
    await fs.access(a.video);
  } catch {
    console.log(JSON.stringify({ verdict: "fail", reasons: [`video not found: ${a.video}`] }));
    process.exit(1);
  }

  const expected = a.expected || (await readMaybe(a.expectedFile, "(no expected steps provided)"));
  let signals = { console: [], html: null };
  const sigTxt = await readMaybe(a.signalsFile, null);
  if (sigTxt) {
    try {
      signals = JSON.parse(sigTxt);
    } catch {}
  }

  const verdict = await verifyRecording({ video: a.video, expected, signals, frames: a.frames });
  console.log(JSON.stringify(verdict, null, 2));
  // skipped (no key) is non-blocking — treat as pass so the pipeline can still
  // publish when the env has no model key (honestly flagged in the manifest).
  const ok = verdict.verdict === "pass" || verdict.skipped;
  process.exit(ok ? 0 : 1);
}

main().catch((e) => {
  console.error("verify-only fatal:", e);
  process.exit(1);
});
