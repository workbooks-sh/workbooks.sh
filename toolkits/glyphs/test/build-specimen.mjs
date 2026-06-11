// build-specimen.mjs — assemble dist/specimen.html: inline the resolver, the
// open-avatars engine, the curated packs + svgl index + open-peeps bundle, then
// the page markup. Self-contained, opens straight from disk. Zero deps.
// run: node test/build-specimen.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const R = (...p) => join(__dirname, "..", ...p);
const read = (...p) => readFileSync(R(...p), "utf8");

// the resolver + the open-avatars engine, as browser globals (strip ES exports).
const stripEsm = (s) => s.replace(/^export\s.*$/gm, "").replace(/^export\s+default[\s\S]*?;$/gm, "");
const glyphsJs = stripEsm(read("dist", "glyphs.js"));
const avatarsJs = stripEsm(read("packs", "open-avatars", "open-avatars.js"));

const css = read("dist", "glyphs.css");
const brands = read("packs", "curated-brands.json");
const icons = read("packs", "curated-icons.json");
const svglIndex = read("packs", "svgl-index.json");
const openPeeps = read("packs", "open-avatars", "open-peeps.bundle.json");

// the curated brand set — every one is a SYNC hit (instant + offline).
const BRAND_GRID = [
  "google", "nvidia", "anthropic", "openai", "deepmind", "intel",
  "amazon", "apple", "microsoft", "meta", "cloudflare", "github",
  "vercel", "x", "twitter",
];
const ICON_GRID = [
  "html5", "css3", "javascript", "typescript", "react", "vue", "svelte",
  "elixir", "rust", "python", "nodejs", "go", "docker", "git",
  "tailwindcss", "postgresql",
];
const AVATAR_SEEDS = ["wren", "moss", "hale", "desk", "ada", "june"];
const SOCIAL = [["github", "octocat"], ["twitter", "x"], ["github", "torvalds"]];

const html = `<!doctype html>
<html lang="en" data-glyphs-specimen>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>glyphs — specimen</title>
<style>
${css}
:root { --ink:#0b0b0c; --paper:#fff; --faint:#6b7280; --rule:#ececec; --green:#00ff44; }
* { box-sizing: border-box; }
body { margin:0; background:var(--paper); color:var(--ink);
  font:16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, system-ui, sans-serif; }
.wrap { max-width: 980px; margin: 0 auto; padding: 4rem 1.5rem 6rem; }
h1 { font-size: 2.4rem; letter-spacing:-.02em; margin:0 0 .25rem; }
.tag { color: var(--faint); margin: 0 0 3rem; max-width: 60ch; }
h2 { font-size: 1.05rem; text-transform: uppercase; letter-spacing:.08em;
  color: var(--faint); margin: 3rem 0 1rem; border-bottom:1px solid var(--rule); padding-bottom:.5rem; }
.grid { display:grid; grid-template-columns: repeat(auto-fill, minmax(120px,1fr)); gap: 1rem; }
.cell { display:flex; flex-direction:column; align-items:center; gap:.5rem;
  padding:1.25rem .5rem; border:1px solid var(--rule); border-radius:12px; }
.cell .mark { font-size: 40px; line-height:0; display:flex; align-items:center; justify-content:center; height:48px; }
.cell .ref { font: 12px ui-monospace, "SF Mono", Menlo, monospace; color: var(--faint); }
.cell .miss { font-size:12px; color:#c00; }
.headline { font-size: 2rem; line-height:1.3; letter-spacing:-.01em; margin: 1rem 0; font-weight:650; }
.headline .glyph { font-size:1.1em; margin:0 .12em; }
.sentence { font-size:1.15rem; color:#222; }
.try { display:flex; gap:.75rem; align-items:center; margin:1rem 0; flex-wrap:wrap; }
.try input { font:14px ui-monospace, Menlo, monospace; padding:.6rem .8rem; border:1px solid var(--rule);
  border-radius:8px; min-width:260px; }
.try .out { font-size:44px; line-height:0; min-width:56px; height:56px; display:flex; align-items:center; }
.try .status { font:13px ui-monospace, Menlo, monospace; color:var(--faint); }
.note { color:var(--faint); font-size:.9rem; }
.mono-demo { display:flex; gap:2rem; align-items:center; }
.mono-demo .mark { font-size:40px; line-height:0; }
</style>
</head>
<body>
<div class="wrap">
  <h1>glyphs</h1>
  <p class="tag">One API resolves any visual mark — brand logo, tech icon, seeded
  avatar, social avatar — to an SVG (or an <code>&lt;img&gt;</code>). Curated-local
  first, CDN fallback for the long tail. <code>glyph(ref)</code> is sync
  (curated-only); <code>glyphAsync(ref)</code> hits the CDN.</p>

  <h2>brand: — full-color logos (curated)</h2>
  <div class="grid" id="brands"></div>

  <h2>icon: — tech / UI icons (curated)</h2>
  <div class="grid" id="icons"></div>

  <h2>mono: — force grayscale on a full-color brand</h2>
  <div class="mono-demo">
    <span class="mark" id="mono-color"></span>
    <span class="mark" id="mono-gray"></span>
    <span class="note">left: native color · right: <code>{ mono: true }</code></span>
  </div>

  <h2>avatar: — delegated to open-avatars (deterministic by seed)</h2>
  <div class="grid" id="avatars"></div>

  <h2>social: — unavatar lookup (a real &lt;img&gt;, network)</h2>
  <div class="grid" id="social"></div>

  <h2>inline in a headline — marks at text scale</h2>
  <p class="headline" id="headline"></p>
  <p class="sentence" id="sentence"></p>

  <h2>live — type a ref (e.g. <code>brand:stripe</code>) → resolves from the CDN</h2>
  <div class="try">
    <input id="ref" value="brand:stripe" spellcheck="false">
    <span class="out" id="try-out"></span>
    <span class="status" id="try-status"></span>
  </div>
  <p class="note">Curated marks are instant + offline. The long tail (e.g.
  <code>brand:stripe</code>, <code>icon:zig</code>) needs the network via
  <code>glyphAsync</code> — svgl → lobehub → simple-icons. A true miss renders
  nothing (never a broken-image box). Brand logos are trademarks — nominative /
  identification use only.</p>
</div>

<script>${avatarsJs}</script>
<script>${glyphsJs}</script>
<script type="application/json" id="pack-brands">${brands}</script>
<script type="application/json" id="pack-icons">${icons}</script>
<script type="application/json" id="pack-svgl">${svglIndex}</script>
<script type="application/json" id="pack-peeps">${openPeeps}</script>
<script>
  var J = function(id){ return JSON.parse(document.getElementById(id).textContent); };
  Glyphs.configure({
    brands: J("pack-brands"),
    icons: J("pack-icons"),
    svglIndex: J("pack-svgl"),
    avatarPacks: { "open-peeps": J("pack-peeps") },
    avatarFn: OpenAvatars.avatar,
  });

  function cell(ref, html){
    var d = document.createElement("div"); d.className = "cell";
    var m = document.createElement("span"); m.className = "mark";
    if (html) m.innerHTML = html; else { var x = document.createElement("span"); x.className="miss"; x.textContent="∅ (CDN)"; m.appendChild(x); }
    var r = document.createElement("span"); r.className = "ref"; r.textContent = ref;
    d.appendChild(m); d.appendChild(r); return d;
  }

  var brandRefs = ${JSON.stringify(BRAND_GRID)};
  var iconRefs  = ${JSON.stringify(ICON_GRID)};
  var seeds     = ${JSON.stringify(AVATAR_SEEDS)};
  var social    = ${JSON.stringify(SOCIAL)};

  var bg = document.getElementById("brands");
  brandRefs.forEach(function(n){ var ref="brand:"+n; bg.appendChild(cell(ref, Glyphs.glyph(ref, { size: 40, title: n }))); });

  var ig = document.getElementById("icons");
  iconRefs.forEach(function(n){ var ref="icon:"+n; ig.appendChild(cell(ref, Glyphs.glyph(ref, { size: 40, title: n }))); });

  document.getElementById("mono-color").innerHTML = Glyphs.glyph("brand:google", { size: 40 });
  document.getElementById("mono-gray").innerHTML  = Glyphs.glyph("brand:google", { size: 40, mono: true });

  var ag = document.getElementById("avatars");
  seeds.forEach(function(s){ var ref="avatar:open-peeps/"+s; ag.appendChild(cell(ref, Glyphs.glyph(ref, { size: 56 }))); });

  var sg = document.getElementById("social");
  social.forEach(function(p){ var ref="social:"+p[0]+"/"+p[1]; sg.appendChild(cell(ref, Glyphs.glyph(ref, { size: 56 }))); });

  // inline-in-headline demo — the bit.ml use: a logo sitting in running text.
  document.getElementById("headline").innerHTML =
    Glyphs.glyph("brand:x", { size: "1em" }) + " ships a model that beats " +
    Glyphs.glyph("brand:openai", { size: "1em" }) + " and " +
    Glyphs.glyph("brand:google", { size: "1em" }) + ".";
  document.getElementById("sentence").innerHTML =
    "Built with " + Glyphs.glyph("icon:elixir", { size: "1em" }) +
    " Elixir, " + Glyphs.glyph("icon:rust", { size: "1em" }) +
    " Rust, and a little " + Glyphs.glyph("icon:typescript", { size: "1em" }) + " TypeScript.";

  // live CDN resolver
  var input = document.getElementById("ref");
  var out = document.getElementById("try-out");
  var status = document.getElementById("try-status");
  var t;
  function resolve(){
    var ref = input.value.trim();
    status.textContent = "resolving…"; out.innerHTML = "";
    Glyphs.glyphAsync(ref, { size: 44, title: ref }).then(function(svg){
      if (svg) { out.innerHTML = svg; status.textContent = "resolved"; }
      else { out.innerHTML = ""; status.textContent = "miss → nothing rendered"; }
    });
  }
  input.addEventListener("input", function(){ clearTimeout(t); t = setTimeout(resolve, 350); });
  resolve();
</script>
</body>
</html>`;

writeFileSync(R("dist", "specimen.html"), html);
console.log("wrote dist/specimen.html (" + html.length + " bytes)");
