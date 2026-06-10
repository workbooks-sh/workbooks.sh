// open-avatars tests — plain asserts, zero deps.  run: node test/avatar.test.mjs
import assert from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { avatar, pick, register } from "../dist/open-avatars.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const bundle = JSON.parse(
  readFileSync(join(__dirname, "..", "packs", "open-peeps", "pack.bundle.json"), "utf8")
);

let pass = 0;
function ok(name, cond, detail) {
  if (cond) {
    pass++;
  } else {
    console.error(`FAIL: ${name}${detail ? "\n  " + detail : ""}`);
    process.exitCode = 1;
  }
}

// ---------- determinism is sacred ----------
{
  const a = avatar(bundle, "desk");
  const b = avatar(bundle, "desk");
  ok("same seed → byte-identical", a === b);

  const c = avatar(bundle, "moss");
  ok("different seed → different svg", a !== c);

  // pick() is the pure selection step and must be stable too.
  const p1 = JSON.stringify(pick(bundle, "wren"));
  const p2 = JSON.stringify(pick(bundle, "wren"));
  ok("pick() stable", p1 === p2);

  // Stable across crops for the selection (crop changes framing, not picks).
  const pf = pick(bundle, "hale");
  const af = avatar(bundle, "hale", { crop: "full" });
  ok("full uses the same head atom pick", af.includes(`data-atom="${cssAttr(pf.head)}"`));
}

function cssAttr(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// ---------- valid SVG structure ----------
{
  const s = avatar(bundle, "desk");
  ok("opens with <svg", s.startsWith("<svg"));
  ok("closes </svg>", s.trim().endsWith("</svg>"));
  ok("declares xmlns", s.includes('xmlns="http://www.w3.org/2000/svg"'));
  ok("has a viewBox", /viewBox="[\d. -]+"/.test(s));
  ok("has a <title>", s.includes("<title>"));
  // balanced <g> / </g>
  const opens = (s.match(/<g\b/g) || []).length;
  const closes = (s.match(/<\/g>/g) || []).length;
  ok("balanced <g> tags", opens === closes, `open=${opens} close=${closes}`);
  // no Sketch cruft leaked through the bundler
  ok("no <?xml in output", !s.includes("<?xml"));
  ok("no Sketch generator comment", !s.includes("Generator:"));
  ok("no atom <desc> leaked", !/<desc>/.test(s));
}

// ---------- all (drawn) categories present in output ----------
{
  // full crop draws every category; pick a seed whose optional atoms aren't "None".
  const seed = findSeedWithAll(bundle);
  const s = avatar(bundle, seed, { crop: "full" });
  for (const cat of Object.keys(bundle.categories)) {
    ok(`full output contains ${cat}`, s.includes(`data-cat="${cat}"`), `seed=${seed}`);
  }
}

function findSeedWithAll(b) {
  const cats = Object.keys(b.categories);
  for (let i = 0; i < 5000; i++) {
    const seed = "s" + i;
    const p = pick(b, seed);
    let allNonEmpty = true;
    for (const c of cats) {
      const name = p[c];
      const inner = b.atoms[c][name];
      if (!inner) {
        allNonEmpty = false;
        break;
      }
    }
    if (allNonEmpty) return seed;
  }
  throw new Error("no seed found drawing every category");
}

// ---------- "None" atoms produce no broken group ----------
{
  // Force a seed that selects "* None" for an optional category and confirm we
  // emit NO group for it (empty inner → skipped), so there's no hollow <g></g>.
  let noneSeed = null;
  for (let i = 0; i < 5000; i++) {
    const seed = "n" + i;
    const p = pick(bundle, seed);
    if (bundle.atoms["facial-hair"][p["facial-hair"]] === "") {
      noneSeed = seed;
      break;
    }
  }
  ok("found a None-facial-hair seed", noneSeed !== null);
  if (noneSeed) {
    const s = avatar(bundle, noneSeed, { crop: "full" });
    ok('no empty facial-hair group', !s.includes('data-cat="facial-hair"'), s.slice(0, 200));
    ok("no hollow <g></g>", !/<g[^>]*><\/g>/.test(s));
  }
  // The "* None" atom itself must bundle to an empty string.
  ok('"* None" facial-hair bundles empty', bundle.atoms["facial-hair"]["* None"] === "");
  ok('"* None" accessories bundles empty', bundle.atoms["accessories"]["* None"] === "");
}

// ---------- crop viewBoxes correct ----------
{
  const c = bundle.crops.circle;
  const circle = avatar(bundle, "desk", { crop: "circle" });
  const expectVb = [c.cx - c.r, c.cy - c.r, c.r * 2, c.r * 2].join(" ");
  ok("circle viewBox = disc bbox", circle.includes(`viewBox="${expectVb}"`), `want ${expectVb}`);
  ok("circle has clipPath", circle.includes("<clipPath"));
  ok("circle clips to a <circle>", new RegExp(`<circle cx="${c.cx}" cy="${c.cy}" r="${c.r}"`).test(circle));

  const full = avatar(bundle, "desk", { crop: "full" });
  ok("full viewBox = canvas", full.includes(`viewBox="${bundle.crops.full.viewBox.join(" ")}"`));
  ok("full has no clipPath", !full.includes("<clipPath"));

  const bust = avatar(bundle, "desk", { crop: "bust" });
  ok("bust viewBox matches pack", bust.includes(`viewBox="${bundle.crops.bust.viewBox.join(" ")}"`));
}

// ---------- options ----------
{
  const bg = avatar(bundle, "desk", { crop: "circle", background: "#eee" });
  ok("background draws a filled circle backplate", bg.includes('fill="#eee"'));
  const sized = avatar(bundle, "desk", { size: 128 });
  ok("size sets width/height", sized.includes('width="128"') && sized.includes('height="128"'));
  const sub = avatar(bundle, "desk", { crop: "full", categories: ["body", "head"] });
  ok("categories subset omits face", !sub.includes('data-cat="face"'));
  ok("categories subset keeps head", sub.includes('data-cat="head"'));
}

// ---------- registry + graceful degrade ----------
{
  register(bundle);
  const viaDefault = avatar(null, "desk");
  ok("register() supplies a default bundle", viaDefault === avatar(bundle, "desk"));
  const bad = avatar(null, "x");
  register(null);
  // After clearing, a null pack degrades to a 1×1 svg rather than throwing.
  const degraded = avatar(null, "x");
  ok("null pack degrades, never throws", degraded.startsWith("<svg") && degraded.includes('viewBox="0 0 1 1"'));
}

console.log(`open-avatars: ${pass} checks passed${process.exitCode ? " (with FAILURES)" : ""}`);
