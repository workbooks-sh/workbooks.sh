// Regenerate dist/specimen.html from dist/{orgitorial.js,orgitorial.css} +
// examples/kitchen-sink.org.  Self-contained, zero deps.  run:
//   node test/build-specimen.mjs
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const read = (p) => fs.readFileSync(path.join(root, p), "utf8");

const org = read("examples/kitchen-sink.org");
const css = read("dist/orgitorial.css");
// inline (non-module) script: drop the ES `export` statements (SyntaxError in a
// plain <script>); window.Orgitorial is still set, module.exports is guarded.
const js = read("dist/orgitorial.js")
  .replace(/\nexport \{ render, parseMeta \};\n/, "\n")
  .replace(/\nexport default Orgitorial;\n/, "\n");

const orgSafe = org.replace(/<\/script>/g, "<\\/script>");

const page = `<!doctype html>
<html lang="en" data-org-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>orgitorial — specimen</title>
<style>
/* page chrome — NOT part of the toolkit, just the specimen frame */
* { box-sizing: border-box; }
html, body { margin: 0; }
body { background: var(--org-paper, #fbf9f4); transition: background .2s ease; }
.spec-bar {
  position: sticky; top: 0; z-index: 10;
  display: flex; align-items: center; justify-content: space-between;
  gap: 1rem; padding: .6rem 1.2rem;
  font-family: var(--org-mono, ui-monospace, monospace);
  font-size: .72rem; letter-spacing: .06em; text-transform: uppercase;
  color: var(--org-faint, #8a8378);
  background: color-mix(in oklab, var(--org-paper, #fbf9f4) 88%, transparent);
  backdrop-filter: blur(8px);
  border-bottom: 1px solid var(--org-rule, #e4ddd0);
}
.spec-brand { font-weight: 700; color: var(--org-ink, #1f1d1a); }
.spec-brand b { color: var(--org-accent, #b3411f); }
.spec-toggle {
  font: inherit; cursor: pointer;
  color: var(--org-ink, #1f1d1a);
  background: var(--org-panel, #f4efe6);
  border: 1px solid var(--org-rule-strong, #cfc6b5);
  border-radius: 999px; padding: .35em 1em;
  text-transform: uppercase; letter-spacing: .06em;
}
.spec-toggle:hover { border-color: var(--org-accent, #b3411f); color: var(--org-accent, #b3411f); }
</style>
<style id="orgitorial-css">
${css}
</style>
</head>
<body>
<div class="spec-bar">
  <span class="spec-brand"><b>orgitorial</b> · specimen</span>
  <button class="spec-toggle" id="themeBtn" type="button">Dark</button>
</div>

<!-- the source document, verbatim -->
<script type="text/plain" id="org-source">
${orgSafe}
</script>

<!-- the toolkit renderer (inline, sets window.Orgitorial) -->
<script id="orgitorial-js">
${js}
</script>

<!-- render + theme toggle -->
<script>
(function () {
  var src = document.getElementById("org-source").textContent;
  document.body.insertAdjacentHTML("beforeend", window.Orgitorial.render(src));
  var html = document.documentElement;
  var btn = document.getElementById("themeBtn");
  function set(t) { html.setAttribute("data-org-theme", t); btn.textContent = t === "dark" ? "Light" : "Dark"; }
  btn.addEventListener("click", function () {
    set(html.getAttribute("data-org-theme") === "dark" ? "light" : "dark");
  });
})();
</script>
</body>
</html>
`;

fs.writeFileSync(path.join(root, "dist/specimen.html"), page);
console.log(`specimen.html written (${page.length} bytes)`);
