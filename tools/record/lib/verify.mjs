// The VERIFY cascade — the proof gate. After a capture, a vision model watches
// the recording (sampled to frames) AND reads the console/DOM signals, then
// answers: did it work? any errors? Gates publish, with the cascade:
//
//   Gemini latest (triage, cheap)  -> verdict
//     PASS  -> publish
//     FAIL/uncertain -> Gemini deep (Pro, high-detail) re-check
//        still FAIL -> MiniMax M3 tiebreak (cross-vendor)
//   2-of-3 PASS (or triage-clean) publishes; else the harness retries the take.
//
// OpenRouter chat/completions is image-in, not video-in, so we sample the MP4/
// WebM to N frames with ffmpeg and send them as image_url content with their
// timestamps. Keys: OPENROUTER_API_KEY (env or ~/.workbooks/groundskeeper.env).
// If no key is present, verify SKIPS gracefully (returns {skipped:true}).

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const exec = promisify(execFile);
const OR_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";

const MODELS = {
  triage: process.env.WB_VERIFY_TRIAGE || "google/gemini-3.5-flash",
  deep: process.env.WB_VERIFY_DEEP || "google/gemini-3.1-pro-preview",
  tiebreak: process.env.WB_VERIFY_TIEBREAK || "minimax/minimax-m3",
};

// Read OPENROUTER_API_KEY from env, else parse ~/.workbooks/groundskeeper.env.
export async function resolveKey() {
  if (process.env.OPENROUTER_API_KEY) return process.env.OPENROUTER_API_KEY;
  for (const f of ["groundskeeper.env", "wb-site.env"]) {
    try {
      const txt = await fs.readFile(path.join(os.homedir(), ".workbooks", f), "utf8");
      const m = txt.match(/^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*["']?([^"'\n]+)/m);
      if (m) return m[1];
    } catch {}
  }
  return null;
}

async function ffprobeDuration(file) {
  try {
    const { stdout } = await exec("ffprobe", [
      "-v", "error", "-show_entries", "format=duration",
      "-of", "default=nw=1:nk=1", file,
    ]);
    return parseFloat(stdout.trim()) || 0;
  } catch {
    return 0;
  }
}

// Sample `n` evenly-spaced frames -> PNGs; return [{t, path}].
export async function sampleFrames(file, n = 8) {
  const dur = await ffprobeDuration(file);
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "wb-frames-"));
  const out = [];
  const count = dur > 0 ? n : 1;
  for (let i = 0; i < count; i++) {
    const t = dur > 0 ? (dur * (i + 0.5)) / count : 0;
    const p = path.join(dir, `f${i}.png`);
    try {
      await exec("ffmpeg", ["-y", "-ss", String(t), "-i", file, "-frames:v", "1",
        "-vf", "scale=1280:-1", p]);
      out.push({ t: Number(t.toFixed(2)), path: p });
    } catch {}
  }
  return { frames: out, dur, dir };
}

async function dataUrl(file) {
  const b = await fs.readFile(file);
  return `data:image/png;base64,${b.toString("base64")}`;
}

const SYSTEM = `You are a strict QA verifier for a screen recording of a software UI walkthrough.
You are given evenly-spaced frames (with timestamps) of the recording, the expected
steps the recording was supposed to demonstrate, and the captured browser console +
a DOM snapshot. Decide whether the walkthrough actually WORKED end to end.
Treat as FAILURE: visible error toasts/red text/stack traces/blank or crashed screens,
console "error"/"rejection" entries that indicate a broken feature, or expected UI that
never appears. Reply ONLY with strict JSON, no prose, no markdown:
{"verdict":"pass"|"fail","confidence":0..1,"reasons":[".."],"error_frames":[{"t":sec,"why":".."}]}`;

function buildUserContent(ctx, frames) {
  const content = [
    { type: "text", text:
      `EXPECTED STEPS:\n${ctx.expected}\n\n` +
      `CONSOLE (last entries):\n${JSON.stringify((ctx.signals?.console || []).slice(-30))}\n\n` +
      `DOM SNAPSHOT (truncated):\n${(ctx.signals?.html || "").slice(0, 4000)}\n\n` +
      `FRAMES below are at timestamps: ${frames.map((f) => f.t + "s").join(", ")}.` },
  ];
  for (const f of frames) {
    content.push({ type: "text", text: `--- frame @ ${f.t}s ---` });
    content.push({ type: "image_url", image_url: { url: f._url } });
  }
  return content;
}

async function callModel(key, model, ctx, frames) {
  const messages = [
    { role: "system", content: SYSTEM },
    { role: "user", content: buildUserContent(ctx, frames) },
  ];
  const res = await fetch(OR_ENDPOINT, {
    method: "POST",
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
    // headroom: reasoning models (Gemini Pro) spend tokens before the JSON;
    // too low a cap truncates the answer to an empty/partial object.
    body: JSON.stringify({ model, messages, temperature: 0, max_tokens: 4000,
      response_format: { type: "json_object" } }),
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`OpenRouter ${model} HTTP ${res.status}: ${t.slice(0, 200)}`);
  }
  const json = await res.json();
  const txt = json.choices?.[0]?.message?.content || "";
  let parsed;
  try {
    parsed = JSON.parse(txt);
  } catch {
    const m = txt.match(/\{[\s\S]*\}/);
    parsed = m ? JSON.parse(m[0]) : { verdict: "fail", confidence: 0, reasons: ["unparseable verifier output"] };
  }
  // normalize: a truncated/odd response without a verdict counts as fail, not undefined
  if (parsed.verdict !== "pass" && parsed.verdict !== "fail") {
    parsed = { verdict: "fail", confidence: 0, reasons: ["verifier returned no clear verdict"], ...parsed, verdict: "fail" };
  }
  parsed._model = json.model || model;
  parsed._cost = json.usage?.cost;
  return parsed;
}

// Main entry. ctx = { video, expected, signals, frames? }
export async function verifyRecording(ctx) {
  const key = await resolveKey();
  if (!key) return { skipped: true, reason: "no OPENROUTER_API_KEY (env / ~/.workbooks)", verdict: "skip" };

  const nFrames = ctx.frames || 8;
  const { frames, dir } = await sampleFrames(ctx.video, nFrames);
  if (!frames.length) return { skipped: true, reason: "no frames sampled (ffmpeg/empty video)", verdict: "skip" };
  for (const f of frames) f._url = await dataUrl(f.path);

  const trail = [];
  const finish = async (result) => {
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
    return { ...result, trail, skipped: false };
  };

  // 1) triage
  let triage;
  try {
    triage = await callModel(key, MODELS.triage, ctx, frames);
    trail.push({ stage: "triage", ...triage });
  } catch (e) {
    return finish({ verdict: "error", reason: String(e.message) });
  }
  if (triage.verdict === "pass" && (triage.confidence ?? 1) >= 0.6) {
    return finish({ verdict: "pass", confidence: triage.confidence, by: "triage" });
  }

  // 2) deep re-check
  let deep;
  try {
    deep = await callModel(key, MODELS.deep, ctx, frames);
    trail.push({ stage: "deep", ...deep });
  } catch (e) {
    trail.push({ stage: "deep", error: String(e.message) });
    deep = null;
  }
  if (deep && deep.verdict === "pass" && (deep.confidence ?? 1) >= 0.6) {
    return finish({ verdict: "pass", confidence: deep.confidence, by: "deep" });
  }

  // 3) tiebreak (cross-vendor) — 2-of-3 rule
  let tie;
  try {
    tie = await callModel(key, MODELS.tiebreak, ctx, frames);
    trail.push({ stage: "tiebreak", ...tie });
  } catch (e) {
    trail.push({ stage: "tiebreak", error: String(e.message) });
    tie = null;
  }
  const votes = [triage, deep, tie].filter(Boolean).map((v) => v.verdict);
  const passes = votes.filter((v) => v === "pass").length;
  const verdict = passes >= 2 ? "pass" : "fail";
  return finish({
    verdict,
    by: "vote",
    votes,
    error_frames: (deep || triage)?.error_frames || [],
    reasons: (deep || triage)?.reasons || [],
  });
}
