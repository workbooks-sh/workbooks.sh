// Regenerate dist/specimen.html — a UNIFIED gallery of every avatar style from
// the single avatar() API. One section per pack, all showing the SAME seed set
// so you can see one identity across every art style. Plus a global seed input
// that updates every style at once.  Self-contained, zero deps.
//   run: node test/build-specimen.mjs
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const read = (p) => fs.readFileSync(path.join(root, p), "utf8");
const json = (p) => JSON.parse(read(p));

// Inline (non-module) renderer: drop ES `export` lines; window.OpenAvatars set.
const coreJs = read("dist/open-avatars.js")
  .replace(/\nexport \{[^}]*\};\n/, "\n")
  .replace(/\nexport default OpenAvatars;\n/, "\n");

// Turn a procedural generate.js ES module into a plain script that assigns a
// global `OA_<name>` = { generate }.  We strip the `export` keywords and the
// trailing default export, then append the global assignment.
function proceduralScript(name) {
  let src = read(`packs/${name}/generate.js`);
  src = src
    .replace(/export function generate/, "function generate")
    .replace(/\nexport default[^\n]*\n/, "\n");
  return src + `\nwindow.OA_${name} = { generate: generate };\n`;
}

const SEEDS = [
  "bit.ml", "ada", "grace", "linus", "margaret",
  "river", "ember", "atlas", "wren", "sol", "indigo", "cyan",
];

const peeps = read("packs/open-peeps/pack.bundle.json").replace(/<\/script>/g, "<\\/script>");
const trans = read("packs/transhumans/pack.bundle.json").replace(/<\/script>/g, "<\\/script>");
const pixIds = read("packs/pixabots/pixabots.ids.json").replace(/<\/script>/g, "<\\/script>");

const peepsMeta = json("packs/open-peeps/pack.json");
const transMeta = json("packs/transhumans/pack.json");

// per-pack note metadata for the UI
const NOTES = {
  "open-peeps": { type: "assembled", license: peepsMeta.license, source: "openpeeps.com" },
  transhumans: { type: "gallery · svg", license: transMeta.license, source: "transhuman.club" },
  pixabots: { type: "gallery · raster", license: "see LICENSE.txt", source: "pixabots" },
  boring: { type: "procedural", license: "MIT", source: "boringdesigners/boring-avatars" },
  jdenticon: { type: "procedural", license: "MIT", source: "dmester/jdenticon" },
  minidenticons: { type: "procedural", license: "MIT", source: "laurentpayot/minidenticons" },
  pixitar: { type: "procedural", license: "MIT", source: "ptcodes/pixitar" },
};

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>open-avatars — specimen</title>
<style>
* { box-sizing: border-box; }
html, body { margin: 0; }
body {
  background: #ffffff; color: #111;
  font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 1180px; margin: 0 auto; padding: 4.5rem 2rem 7rem; }
header.spec { margin-bottom: 3rem; }
.kicker { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: .72rem;
  letter-spacing: .18em; text-transform: uppercase; color: #999; }
h1 { font-size: 2.3rem; font-weight: 650; letter-spacing: -.02em; margin: .5rem 0 .7rem; }
.lede { color: #555; max-width: 54ch; line-height: 1.6; font-size: 1.05rem; }
code { font-family: ui-monospace, Menlo, monospace; font-size: .92em; color: #333; }

.globalseed { position: sticky; top: 0; z-index: 10; background: rgba(255,255,255,.92);
  backdrop-filter: blur(8px); border-bottom: 1px solid #eee; padding: 1rem 0 1.1rem;
  margin: 2.5rem 0 1rem; display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.globalseed label { font-family: ui-monospace, Menlo, monospace; font-size: .68rem;
  letter-spacing: .14em; text-transform: uppercase; color: #aaa; }
.globalseed input { font: inherit; font-size: 1.05rem; padding: .55rem .9rem; min-width: 260px;
  border: 1px solid #ddd; border-radius: 10px; background: #fafafa; color: #111; }
.globalseed input:focus { outline: none; border-color: #111; background: #fff; }
.globalseed .hint { font-size: .8rem; color: #bbb; }

section { margin-top: 3.5rem; }
.section-head { display: flex; align-items: baseline; gap: 1rem; flex-wrap: wrap;
  border-bottom: 1px solid #eee; padding-bottom: .7rem; margin-bottom: 1.8rem; }
.section-head h2 { font-size: 1.15rem; font-weight: 620; margin: 0; letter-spacing: -.01em; }
.section-head .meta { font-family: ui-monospace, Menlo, monospace; font-size: .7rem;
  letter-spacing: .04em; color: #aaa; }
.section-head .meta b { color: #777; font-weight: 600; }

.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(116px, 1fr)); gap: 1.8rem 1.3rem; }
.cell { text-align: center; }
.cell .av { width: 100%; max-width: 104px; margin: 0 auto; aspect-ratio: 1; }
.cell .av svg, .cell .av img { width: 100%; height: 100%; display: block; border-radius: 12px; }
.cell .name { margin-top: .7rem; font-family: ui-monospace, Menlo, monospace;
  font-size: .72rem; color: #999; letter-spacing: .01em; word-break: break-all; }

footer.spec { margin-top: 6rem; padding-top: 2rem; border-top: 1px solid #eee; color: #bbb;
  font-family: ui-monospace, Menlo, monospace; font-size: .72rem; letter-spacing: .04em; line-height: 1.7; }
</style>
</head>
<body>
<div class="wrap">

  <header class="spec">
    <div class="kicker">open-avatars · many styles, one API</div>
    <h1>One seed, every art style</h1>
    <p class="lede">A single <code>avatar(pack, seed, opts)</code> renders seven
      avatar styles — assembled, gallery (SVG &amp; raster), and four procedural
      generators. The <em>same seed set</em> runs down every section, so you see
      one identity wear every art style. Deterministic: same seed → byte-identical
      output, forever.</p>
  </header>

  <div class="globalseed">
    <label for="gseed">global seed</label>
    <input type="text" id="gseed" value="" placeholder="type to set every style at once" autocomplete="off" spellcheck="false">
    <span class="hint">blank = the seed set below</span>
  </div>

  <div id="sections"></div>

  <footer class="spec">
    open-avatars v0.2.0 · type-dispatched avatar engine · zero dependencies<br>
    open-peeps + transhumans art © Pablo Stanley (free for commercial use) ·
    boring-avatars / jdenticon / minidenticons / pixitar are MIT ·
    pixabots per its own LICENSE. See LICENSES.md.
  </footer>
</div>

<!-- bundles (pure JSON) -->
<script type="application/json" id="b-peeps">${peeps}</script>
<script type="application/json" id="b-trans">${trans}</script>
<script type="application/json" id="b-pix">${pixIds}</script>

<!-- the toolkit renderer -->
<script id="oa-core">${coreJs}</script>

<!-- procedural generators (each sets window.OA_<name>) -->
<script>${proceduralScript("boring")}</script>
<script>${proceduralScript("jdenticon")}</script>
<script>${proceduralScript("minidenticons")}</script>
<script>${proceduralScript("pixitar")}</script>

<!-- specimen wiring -->
<script>
(function () {
  var OA = window.OpenAvatars;
  var SEEDS = ${JSON.stringify(SEEDS)};
  var NOTES = ${JSON.stringify(NOTES)};

  var peeps = JSON.parse(document.getElementById("b-peeps").textContent);
  var trans = JSON.parse(document.getElementById("b-trans").textContent);
  var pix = JSON.parse(document.getElementById("b-pix").textContent);

  // procedural packs: a pack object whose generate is the global fn.
  function proc(name) {
    return { type: "procedural", name: name, generate: window["OA_" + name].generate };
  }
  var boring = proc("boring");
  var boringBeam = proc("boring");
  var jdenticon = proc("jdenticon");
  var minidenticons = proc("minidenticons");
  var pixitar = proc("pixitar");

  // pixabots renders from disk: base points at the pack's webp dir, relative to
  // this specimen page (which lives in dist/, so the pack dir is one level up).
  var PIX_BASE = "../packs/pixabots/webp/";

  // Each style is { id, title, render(seed) -> html string }
  var STYLES = [
    { id: "open-peeps", title: "Open Peeps", render: function (s) {
        return OA.avatar(peeps, s, { crop: "circle", background: "#f4f4f2" }); } },
    { id: "transhumans", title: "Transhumans", render: function (s) {
        return OA.avatar(trans, s, { background: "#f4f4f2" }); } },
    { id: "pixabots", title: "Pixabots", render: function (s) {
        return OA.avatar(pix, s, { base: PIX_BASE }); } },
    { id: "boring", title: "Boring Avatars (marble)", render: function (s) {
        return OA.avatar(boring, s, {}); } },
    { id: "boring", title: "Boring Avatars (beam)", render: function (s) {
        return OA.avatar(boringBeam, s, { variant: "beam" }); } },
    { id: "jdenticon", title: "Jdenticon", render: function (s) {
        return OA.avatar(jdenticon, s, { size: 200, background: "#f4f4f2" }); } },
    { id: "minidenticons", title: "Minidenticons", render: function (s) {
        return OA.avatar(minidenticons, s, {}); } },
    { id: "pixitar", title: "Pixitar (pixel)", render: function (s) {
        return OA.avatar(pixitar, s, {}); } },
  ];

  var container = document.getElementById("sections");

  function buildSection(style) {
    var note = NOTES[style.id] || {};
    var sec = document.createElement("section");
    sec.innerHTML =
      '<div class="section-head">' +
      '<h2>' + style.title + '</h2>' +
      '<span class="meta"><b>' + (note.type || "") + '</b> · ' +
      (note.license || "") + ' · ' + (note.source || "") + '</span>' +
      '</div><div class="grid"></div>';
    sec._grid = sec.querySelector(".grid");
    container.appendChild(sec);
    return sec;
  }
  var sections = STYLES.map(buildSection);

  function paint() {
    var override = document.getElementById("gseed").value.trim();
    var seeds = override ? [override] : SEEDS;
    STYLES.forEach(function (style, i) {
      var grid = sections[i]._grid;
      grid.innerHTML = seeds.map(function (s) {
        return '<div class="cell"><div class="av">' + style.render(s) +
          '</div><div class="name">' + escHtml(s) + '</div></div>';
      }).join("");
    });
  }
  function escHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  document.getElementById("gseed").addEventListener("input", paint);
  paint();
})();
</script>
</body>
</html>
`;

fs.writeFileSync(path.join(root, "dist/specimen.html"), page);
console.log(`specimen.html written (${(page.length / 1024 / 1024).toFixed(2)} MB)`);
