// Regenerate dist/specimen.html from dist/open-avatars.js +
// packs/open-peeps/pack.bundle.json.  Self-contained, zero deps.  run:
//   node test/build-specimen.mjs
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const read = (p) => fs.readFileSync(path.join(root, p), "utf8");

// inline (non-module) script: drop the ES `export` statements (SyntaxError in a
// plain <script>); window.OpenAvatars is still set, module.exports is guarded.
const js = read("dist/open-avatars.js")
  .replace(/\nexport \{[^}]*\};\n/, "\n")
  .replace(/\nexport default OpenAvatars;\n/, "\n");

const bundleRaw = read("packs/open-peeps/pack.bundle.json");
const bundleSafe = bundleRaw.replace(/<\/script>/g, "<\\/script>");

const SEEDS = [
  "desk", "moss", "wren", "hale",
  "river", "ember", "atlas", "wolf", "fern", "sol",
  "indigo", "cove", "birch", "echo", "vale", "north",
  "pike", "marlow", "june", "cyan", "onyx", "lark",
  "reed", "ash",
];

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>open-avatars — specimen</title>
<style>
/* page chrome — NOT part of the toolkit, just the specimen frame */
* { box-sizing: border-box; }
html, body { margin: 0; }
body {
  background: #ffffff; color: #111;
  font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 1080px; margin: 0 auto; padding: 4.5rem 2rem 6rem; }
header.spec { margin-bottom: 4rem; }
.kicker {
  font-family: ui-monospace, "SF Mono", Menlo, monospace;
  font-size: .72rem; letter-spacing: .18em; text-transform: uppercase;
  color: #999;
}
h1 { font-size: 2.1rem; font-weight: 650; letter-spacing: -.02em; margin: .5rem 0 .6rem; }
.lede { color: #555; max-width: 46ch; line-height: 1.55; font-size: 1.02rem; }
section { margin-top: 4.5rem; }
.section-label {
  font-family: ui-monospace, "SF Mono", Menlo, monospace;
  font-size: .72rem; letter-spacing: .16em; text-transform: uppercase;
  color: #aaa; border-bottom: 1px solid #eee; padding-bottom: .6rem; margin-bottom: 2rem;
}

/* the avatar grid */
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(132px, 1fr)); gap: 2rem 1.5rem; }
.cell { text-align: center; }
.cell .av { width: 100%; max-width: 120px; margin: 0 auto; }
.cell .av svg { width: 100%; height: auto; display: block; }
.cell .name {
  margin-top: .85rem;
  font-family: ui-monospace, "SF Mono", Menlo, monospace;
  font-size: .74rem; color: #888; letter-spacing: .02em;
}

/* live seed input */
.try { display: flex; flex-wrap: wrap; align-items: center; gap: 2.5rem; margin-top: 1rem; }
.try .preview { width: 200px; height: 200px; flex: 0 0 auto; }
.try .preview svg { width: 100%; height: 100%; display: block; }
.controls { flex: 1 1 280px; min-width: 260px; }
.controls label {
  display: block; font-family: ui-monospace, Menlo, monospace;
  font-size: .7rem; letter-spacing: .12em; text-transform: uppercase; color: #aaa; margin-bottom: .5rem;
}
input[type=text] {
  width: 100%; font: inherit; font-size: 1.05rem; padding: .7rem .9rem;
  border: 1px solid #ddd; border-radius: 10px; background: #fafafa; color: #111;
}
input[type=text]:focus { outline: none; border-color: #111; background: #fff; }
.crops { display: inline-flex; margin-top: 1.4rem; border: 1px solid #ddd; border-radius: 999px; overflow: hidden; }
.crops button {
  font: inherit; font-size: .82rem; cursor: pointer; padding: .5em 1.1em;
  background: #fff; color: #555; border: 0; border-right: 1px solid #eee;
  text-transform: capitalize;
}
.crops button:last-child { border-right: 0; }
.crops button[aria-pressed=true] { background: #111; color: #fff; }
.pick {
  margin-top: 1.3rem; font-family: ui-monospace, Menlo, monospace;
  font-size: .76rem; color: #999; line-height: 1.7;
}
.pick b { color: #444; font-weight: 600; }
footer.spec { margin-top: 6rem; padding-top: 2rem; border-top: 1px solid #eee; color: #bbb;
  font-family: ui-monospace, Menlo, monospace; font-size: .72rem; letter-spacing: .04em; }
</style>
</head>
<body>
<div class="wrap">

  <header class="spec">
    <div class="kicker">open-avatars · open-peeps (mono)</div>
    <h1>Deterministic SVG avatars</h1>
    <p class="lede">One seed string → one avatar, forever. Open Peeps atoms by
      Pablo Stanley, composed black-on-white. No randomness, no recoloring —
      pure string&nbsp;→&nbsp;string.</p>
  </header>

  <section>
    <div class="section-label">Try a seed</div>
    <div class="try">
      <div class="preview" id="preview"></div>
      <div class="controls">
        <label for="seed">seed</label>
        <input type="text" id="seed" value="desk" autocomplete="off" spellcheck="false">
        <div class="crops" id="crops">
          <button data-crop="circle" aria-pressed="true">circle</button>
          <button data-crop="bust" aria-pressed="false">bust</button>
          <button data-crop="full" aria-pressed="false">full</button>
        </div>
        <div class="pick" id="pick"></div>
      </div>
    </div>
  </section>

  <section>
    <div class="section-label">The crew &amp; twenty-two more — circle crop</div>
    <div class="grid" id="grid"></div>
  </section>

  <footer class="spec">open-avatars v0.1.0 · CC0 atoms · zero dependencies</footer>
</div>

<!-- the pack bundle (pure JSON) -->
<script type="application/json" id="oa-bundle">
${bundleSafe}
</script>

<!-- the toolkit renderer (inline, sets window.OpenAvatars) -->
<script id="oa-js">
${js}
</script>

<!-- specimen wiring -->
<script>
(function () {
  var bundle = JSON.parse(document.getElementById("oa-bundle").textContent);
  var OA = window.OpenAvatars;
  OA.register(bundle);

  var SEEDS = ${JSON.stringify(SEEDS)};

  // grid of seeded avatars at circle crop
  var grid = document.getElementById("grid");
  grid.innerHTML = SEEDS.map(function (s) {
    return '<div class="cell"><div class="av">' +
      OA.avatar(bundle, s, { crop: "circle", background: "#f4f4f2" }) +
      '</div><div class="name">' + s + '</div></div>';
  }).join("");

  // live preview
  var seedEl = document.getElementById("seed");
  var preview = document.getElementById("preview");
  var pickEl = document.getElementById("pick");
  var crop = "circle";

  function fmtPick(p) {
    return Object.keys(p).map(function (k) {
      return k + ': <b>' + p[k] + '</b>';
    }).join("<br>");
  }

  function paint() {
    var seed = seedEl.value || "";
    preview.innerHTML = OA.avatar(bundle, seed, {
      crop: crop,
      background: crop === "circle" ? "#f4f4f2" : "#ffffff",
    });
    pickEl.innerHTML = fmtPick(OA.pick(bundle, seed));
  }

  seedEl.addEventListener("input", paint);

  document.getElementById("crops").addEventListener("click", function (e) {
    var btn = e.target.closest("button");
    if (!btn) return;
    crop = btn.getAttribute("data-crop");
    [].forEach.call(this.querySelectorAll("button"), function (b) {
      b.setAttribute("aria-pressed", b === btn ? "true" : "false");
    });
    paint();
  });

  paint();
})();
</script>
</body>
</html>
`;

fs.writeFileSync(path.join(root, "dist/specimen.html"), page);
console.log(`specimen.html written (${(page.length / 1024).toFixed(1)} KB)`);
