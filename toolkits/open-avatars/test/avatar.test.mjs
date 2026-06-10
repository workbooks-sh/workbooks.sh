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

// =====================================================================
// GALLERY pack — transhumans (type: gallery, kind: svg)
// =====================================================================
{
  const trans = JSON.parse(
    readFileSync(join(__dirname, "..", "packs", "transhumans", "pack.bundle.json"), "utf8")
  );
  ok("transhumans is a gallery/svg pack", trans.type === "gallery" && trans.kind === "svg");

  const a = avatar(trans, "desk");
  const b = avatar(trans, "desk");
  ok("gallery: same seed → byte-identical", a === b);
  ok("gallery: different seed → different svg", a !== avatar(trans, "moss"));

  ok("gallery: valid svg", a.startsWith("<svg") && a.trim().endsWith("</svg>"));
  ok("gallery: declares xmlns", a.includes('xmlns="http://www.w3.org/2000/svg"'));
  ok("gallery: square viewBox", a.includes('viewBox="0 0 1080 1080"'));
  ok("gallery: has <title>", a.includes("<title>"));
  ok("gallery: records chosen id", /data-id="[^"]+"/.test(a));

  // pick() returns the chosen id, and it is one of the gallery ids.
  const id = pick(trans, "desk");
  ok("gallery pick() returns an id present in items", trans.items[id] != null);
  ok("gallery pick() matches avatar()'s data-id", a.includes(`data-id="${cssAttr(id)}"`));

  // pick is a deterministic FNV pick over the SORTED id list.
  const ids = Object.keys(trans.items).sort();
  const expect = ids[fnv1a("desk") % ids.length];
  ok("gallery pick() = FNV over sorted ids", id === expect, `got ${id} want ${expect}`);

  // background option draws a backplate rect.
  const bg = avatar(trans, "desk", { background: "#eee" });
  ok("gallery: background draws a rect backplate", bg.includes('fill="#eee"'));
}

// local FNV-1a mirror so the test can recompute the expected gallery pick.
function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

// =====================================================================
// GALLERY raster pack — pixabots (type: gallery, kind: raster)
// =====================================================================
{
  const pix = JSON.parse(
    readFileSync(join(__dirname, "..", "packs", "pixabots", "pixabots.ids.json"), "utf8")
  );
  ok("pixabots is a gallery/raster pack", pix.type === "gallery" && pix.kind === "raster");
  ok("pixabots ships an id list, not inlined art", Array.isArray(pix.ids) && pix.ids.length > 0);

  const r1 = avatar(pix, "desk", { base: "x/" });
  const r2 = avatar(pix, "desk", { base: "x/" });
  ok("raster: same seed → identical", r1 === r2);
  ok("raster: returns an <img>", r1.startsWith("<img") && r1.includes("src="));
  ok("raster: src = base + path template", /src="x\/[0-9a-f]{4}\.webp"/.test(r1));
  ok("raster: different seed → different src", r1 !== avatar(pix, "moss", { base: "x/" }));

  // opts.base overrides; default falls back to the pack's recorded base.
  const def = avatar(pix, "desk");
  ok("raster: default base from bundle", def.includes('src="webp/'));
}

// =====================================================================
// PROCEDURAL packs — boring / jdenticon / minidenticons / pixitar
// =====================================================================
{
  const procPacks = [
    { name: "boring", monochrome: false },
    { name: "jdenticon", monochrome: true },
    { name: "minidenticons", monochrome: true },
    { name: "pixitar", monochrome: true },
  ];
  for (const { name, monochrome } of procPacks) {
    const mod = await import(join("..", "packs", name, "generate.js"));
    const pack = { type: "procedural", name, generate: mod.generate };

    const a = avatar(pack, "desk");
    const b = avatar(pack, "desk");
    ok(`${name}: same seed → byte-identical`, a === b);
    ok(`${name}: different seed → different svg`, a !== avatar(pack, "moss"));
    ok(`${name}: valid svg`, a.startsWith("<svg") && a.trim().endsWith("</svg>"));
    ok(`${name}: declares xmlns`, a.includes('xmlns="http://www.w3.org/2000/svg"'));
    ok(`${name}: has <title>`, a.includes("<title>"));

    // generate() called directly is the same as via avatar() (pure pass-through).
    ok(`${name}: avatar() == generate()`, a === mod.generate("desk", {}));

    // monochrome opt where supported: changes output and removes saturated hue.
    if (monochrome) {
      const mono = avatar(pack, "desk", { monochrome: true });
      ok(`${name}: monochrome opt changes output`, mono !== a);
      ok(`${name}: monochrome is grayscale`, !/hsl\(\s*[1-9]/.test(mono) || mono.includes("hsl(0 0%"));
    }
  }

  // boring variant switch (marble vs beam) is deterministic and distinct.
  const boring = await import(join("..", "packs", "boring", "generate.js"));
  const marble = boring.generate("desk", { variant: "marble" });
  const beam = boring.generate("desk", { variant: "beam" });
  ok("boring: marble viewBox 80", marble.includes('viewBox="0 0 80 80"'));
  ok("boring: beam viewBox 36", beam.includes('viewBox="0 0 36 36"'));
  ok("boring: marble ≠ beam", marble !== beam);
  ok("boring: marble stable", marble === boring.generate("desk", { variant: "marble" }));
}

// ---------- procedural pack: bad generate degrades, never throws ----------
{
  const broken = { type: "procedural", name: "x" }; // no generate fn
  const out = avatar(broken, "desk");
  ok("procedural without generate() degrades", out.startsWith("<svg"));
  const throws = { type: "procedural", generate: () => { throw new Error("boom"); } };
  ok("procedural that throws degrades, never propagates", avatar(throws, "desk").startsWith("<svg"));
}

console.log(`open-avatars: ${pass} checks passed${process.exitCode ? " (with FAILURES)" : ""}`);
