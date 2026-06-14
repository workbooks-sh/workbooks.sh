// timecode — the frames<->timecode clock shared by the driver and the voiceover.
//
// CANONICAL INTERNAL UNIT = FRAMES. Everything (cue scheduling, audio delays,
// drift) is computed in integer frames at the demo's FPS, then converted to
// seconds only at the ffmpeg boundary. This is what makes narration and on-screen
// action frame-accurate against the SAME clock.
//
// Accepted timecode string forms (parsed by toFrames):
//   "SS"            seconds            -> 5      => 5s
//   "MM:SS"         minutes:seconds    -> 01:03  => 63s
//   "HH:MM:SS"      hours:minutes:secs -> 00:01:03
//   "HH:MM:SS:FF"   SMPTE, FF = frames -> 00:00:02:15  (2s + 15 frames)
//   "fN"            raw frame number   -> f90    => frame 90 (fps-independent)
//   number          treated as seconds (a bare numeric literal from the parser)
//
// Pure functions only — no I/O. selfTest() round-trips every form at 24/30/60.

// Parse a timecode string (or number) to an integer frame index at `fps`.
export function toFrames(tc, fps) {
  if (!Number.isFinite(fps) || fps <= 0) throw new Error(`toFrames: bad fps ${fps}`);
  if (typeof tc === "number") return Math.round(tc * fps);
  const s = String(tc).trim();
  // raw frames: fN
  const fm = /^f(\d+)$/i.exec(s);
  if (fm) return parseInt(fm[1], 10);
  const parts = s.split(":");
  if (parts.length === 1) {
    // bare seconds (may be fractional)
    const sec = Number(parts[0]);
    if (!Number.isFinite(sec)) throw new Error(`toFrames: cannot parse "${tc}"`);
    return Math.round(sec * fps);
  }
  if (parts.length === 2) {
    // MM:SS
    const [mm, ss] = parts.map(Number);
    if (![mm, ss].every(Number.isFinite)) throw new Error(`toFrames: cannot parse "${tc}"`);
    return Math.round((mm * 60 + ss) * fps);
  }
  if (parts.length === 3) {
    // HH:MM:SS
    const [hh, mm, ss] = parts.map(Number);
    if (![hh, mm, ss].every(Number.isFinite)) throw new Error(`toFrames: cannot parse "${tc}"`);
    return Math.round((hh * 3600 + mm * 60 + ss) * fps);
  }
  if (parts.length === 4) {
    // HH:MM:SS:FF (SMPTE — FF is whole frames, not subseconds)
    const [hh, mm, ss, ff] = parts.map(Number);
    if (![hh, mm, ss, ff].every(Number.isFinite)) throw new Error(`toFrames: cannot parse "${tc}"`);
    return Math.round((hh * 3600 + mm * 60 + ss) * fps) + ff;
  }
  throw new Error(`toFrames: cannot parse "${tc}"`);
}

// Frame index -> seconds (float). The ffmpeg boundary.
export function toSeconds(frame, fps) {
  if (!Number.isFinite(fps) || fps <= 0) throw new Error(`toSeconds: bad fps ${fps}`);
  return frame / fps;
}

// Frame index -> canonical SMPTE HH:MM:SS:FF string (for logs / timing.json).
export function fmt(frame, fps) {
  if (!Number.isFinite(fps) || fps <= 0) throw new Error(`fmt: bad fps ${fps}`);
  const ff = Math.round(frame % fps);
  const totalSec = Math.floor(frame / fps);
  const ss = totalSec % 60;
  const mm = Math.floor(totalSec / 60) % 60;
  const hh = Math.floor(totalSec / 3600);
  const p2 = (n) => String(n).padStart(2, "0");
  return `${p2(hh)}:${p2(mm)}:${p2(ss)}:${p2(ff)}`;
}

// Tiny self-test: round-trip each accepted form at fps 24/30/60. Returns
// { ok, cases:[{fps,in,frames,back,pass}], fails }. The pipeline can run it.
export function selfTest() {
  const cases = [];
  let fails = 0;
  const check = (cond, detail) => {
    cases.push(detail);
    if (!cond) fails++;
  };
  for (const fps of [24, 30, 60]) {
    // "SS"
    check(toFrames("5", fps) === 5 * fps, { fps, in: "5", got: toFrames("5", fps), want: 5 * fps, pass: toFrames("5", fps) === 5 * fps });
    // "MM:SS"
    check(toFrames("01:03", fps) === 63 * fps, { fps, in: "01:03", got: toFrames("01:03", fps), want: 63 * fps, pass: toFrames("01:03", fps) === 63 * fps });
    // "HH:MM:SS"
    check(toFrames("00:01:03", fps) === 63 * fps, { fps, in: "00:01:03", got: toFrames("00:01:03", fps), want: 63 * fps, pass: toFrames("00:01:03", fps) === 63 * fps });
    // "HH:MM:SS:FF" — 2s + 15 frames
    {
      const want = 2 * fps + 15;
      const got = toFrames("00:00:02:15", fps);
      check(got === want, { fps, in: "00:00:02:15", got, want, pass: got === want });
    }
    // "fN" — fps-independent
    check(toFrames("f90", fps) === 90, { fps, in: "f90", got: toFrames("f90", fps), want: 90, pass: toFrames("f90", fps) === 90 });
    // toSeconds round-trip on a clean frame
    {
      const fr = 3 * fps;
      const sec = toSeconds(fr, fps);
      const back = toFrames(sec, fps);
      check(back === fr, { fps, in: `toSeconds(${fr})=${sec}->frames`, got: back, want: fr, pass: back === fr });
    }
    // fmt round-trip
    {
      const fr = 2 * fps + 15;
      const str = fmt(fr, fps);
      const back = toFrames(str, fps);
      check(back === fr, { fps, in: `fmt(${fr})=${str}->frames`, got: back, want: fr, pass: back === fr });
    }
  }
  return { ok: fails === 0, fails, cases };
}

// Run directly: `node lib/timecode.mjs` -> prints self-test, exits 0/1.
if (import.meta.url === `file://${process.argv[1]}`) {
  const r = selfTest();
  for (const c of r.cases) {
    process.stdout.write(`${c.pass ? "ok  " : "FAIL"} fps=${c.fps} ${c.in} => ${c.got} (want ${c.want})\n`);
  }
  process.stdout.write(`\n${r.ok ? "PASS" : "FAIL"}: ${r.cases.length - r.fails}/${r.cases.length} round-trips\n`);
  process.exit(r.ok ? 0 : 1);
}
