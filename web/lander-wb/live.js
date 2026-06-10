// live.js — the page builds itself in front of a real DevTools-style panel.
// The panel SHIFTS the layout (a docked pane, not an overlay): Elements shows
// the page's live DOM, Console streams the agent's build log + activity, Sources
// shows the workbook's own source, Agent holds the keeper's rules + changelog.

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, r = document) => r.querySelector(s);
const docEl = document.documentElement;
const LIVE = location.pathname.startsWith("/live") ? "/live" : "";
const esc = s => (s || "").replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
const wait = ms => new Promise(r => setTimeout(r, ms));

/* ── panel open/close: shifts the layout via html[data-insp] ── */
const setInsp = on => docEl.setAttribute("data-insp", on ? "open" : "closed");
$("#insp-handle")?.addEventListener("click", () => setInsp(true));
$("#insp-close")?.addEventListener("click", () => setInsp(false));
$("#cta-inspect")?.addEventListener("click", e => { e.preventDefault(); setInsp(true); selectTab("elements"); });

function selectTab(name) {
  document.querySelectorAll(".dt-tab").forEach(t => t.classList.toggle("on", t.dataset.pane === name));
  document.querySelectorAll(".dt-pane").forEach(p => p.classList.toggle("on", p.id === "dt-" + name));
  if (name === "elements") buildTree();
  if (name === "sources") buildSource();
}
document.querySelectorAll(".dt-tab").forEach(t => t.addEventListener("click", () => selectTab(t.dataset.pane)));

/* ── Elements: render the page's REAL DOM as a colorized tree ── */
let treeBuilt = false;
function buildTree() {
  if (treeBuilt) return; treeBuilt = true;
  const out = [];
  const squash = (s, n = 90) => { s = (s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n) + "…" : s; };
  function render(node, depth) {
    const pad = "  ".repeat(depth);
    if (node.nodeType === 8) {
      const t = squash(node.textContent, 120);
      out.push(`<span class="row cm">${pad}&lt;!-- ${esc(t)} --&gt;</span>`); return;
    }
    if (node.nodeType === 3) { const t = squash(node.textContent); if (t) out.push(`<span class="row tx">${pad}${esc(t)}</span>`); return; }
    if (node.nodeType !== 1) return;
    if (node.id === "insp" || node.id === "insp-handle" || node.id === "presence") return; // don't inspect the tools
    const tag = node.tagName.toLowerCase();
    let attrs = "";
    for (const a of node.attributes) {
      let v = a.value; if (v.length > 36) v = v.slice(0, 30) + "…";
      attrs += ` <span class="an">${esc(a.name)}</span>=<span class="av">"${esc(v)}"</span>`;
    }
    const VOID = ["meta","link","br","img","input","hr","source","path","use"];
    const opaque = ["script", "style", "svg", "canvas", "iframe", "path"].includes(tag);
    const kids = [...node.childNodes].filter(n => n.nodeType === 1 || n.nodeType === 8 || (n.nodeType === 3 && n.textContent.trim()));
    if (VOID.includes(tag)) { out.push(`<span class="row"><span class="tag">${pad}&lt;${tag}</span>${attrs}<span class="tag">&gt;</span></span>`); return; }
    if (!kids.length || opaque) {
      out.push(`<span class="row"><span class="tag">${pad}&lt;${tag}</span>${attrs}<span class="tag">&gt;</span>${opaque && kids.length ? '<span class="cm">…</span>' : ""}<span class="tag">&lt;/${tag}&gt;</span></span>`);
      return;
    }
    out.push(`<span class="row"><span class="tag">${pad}&lt;${tag}</span>${attrs}<span class="tag">&gt;</span></span>`);
    if (depth < 7) for (const k of kids) render(k, depth + 1);
    else out.push(`<span class="row cm">${pad}  …</span>`);
    out.push(`<span class="row"><span class="tag">${pad}&lt;/${tag}&gt;</span></span>`);
  }
  out.push(`<span class="row cm">&lt;!DOCTYPE html&gt;</span>`);
  render(docEl, 0);
  $("#dom-tree").innerHTML = out.join("");
}

/* ── Sources: the workbook's own source ── */
let srcBuilt = false;
function buildSource() {
  if (srcBuilt) return; srcBuilt = true;
  const raw = "<!doctype html>\n" + docEl.outerHTML;
  $("#src-body").textContent = raw.length > 60000 ? raw.slice(0, 60000) + "\n…" : raw;
}

/* ── Console: the agent's log ── */
const clog = $("#console-log");
function con(html, cls = "") { const d = document.createElement("div"); d.className = "ln " + cls; d.innerHTML = html; clog?.appendChild(d); clog && (clog.scrollTop = clog.scrollHeight); return d; }

/* ── the build ── */
const blocks = [...document.querySelectorAll("[data-build]")];
const labelFor = el => el.closest(".hero") ? "hero" : (el.closest("section")?.id || "section");
const presence = $("#presence"), ptext = $("#p-text");

async function build() {
  if (reduce) { blocks.forEach(b => b.classList.add("built")); afterBuild(); return; }
  blocks.forEach(b => b.classList.add("building"));
  if (ptext) ptext.textContent = "lander-keeper is building this page";
  setInsp(true); selectTab("console");
  con(`<span class="pr">$</span> wb agent run <span class="kw">"compose workbooks.sh"</span>`);
  await wait(650);
  for (const b of blocks) {
    const name = labelFor(b);
    const line = con(`<span class="dim">∙</span> composing <span class="kw">${esc(name)}</span> …`);
    await wait(500);
    b.classList.remove("building"); b.classList.add("built");
    line.innerHTML = `<span class="dim">∙</span> composing <span class="kw">${esc(name)}</span> <span class="ok">✓</span>`;
    await wait(160);
  }
  con(`rendered ${blocks.length} blocks · <span class="ok">live</span>`);
  await wait(900);
  afterBuild();
}
function afterBuild() {
  if (ptext) { ptext.textContent = "composed just now · maintained live"; presence?.classList.add("settled"); }
  setTimeout(() => presence?.classList.add("fade"), 4500);
  buildTree();
  setTimeout(() => setInsp(false), 2200); // hand the page back full-width; reopen via handle / hero CTA
  poll(true); setInterval(() => poll(false), 30000);
  startMakePrompt();
}
build();

/* ── make-prompt: cycle example requests, typed ── */
function startMakePrompt() {
  const mp = $("#mp-text"); if (!mp) return;
  if (reduce) { mp.textContent = "a reading list with covers"; return; }
  const ex = ["a reading list with covers", "a workout log", "a client CRM", "a recipe box", "a standup tracker"];
  let i = 0;
  (async function cycle() {
    while (true) {
      const s = ex[i % ex.length];
      for (let k = 1; k <= s.length; k++) { mp.textContent = s.slice(0, k); await wait(45); }
      await wait(1500);
      for (let k = s.length; k >= 0; k--) { mp.textContent = s.slice(0, k); await wait(22); }
      await wait(350); i++;
    }
  })();
}

/* ── live changelog (Agent tab) + console echo + footer status ── */
const chglog = $("#chglog"), chgSrc = $("#chg-src");
const liveStatus = $("#live-status"), liveText = $("#live-text");
let headSha = null;
async function poll(first) {
  try {
    const r = await fetch(LIVE + "/_changes", { cache: "no-store" });
    if (!r.ok) return;
    const { changes } = await r.json();
    if (!changes || !changes.length) return;
    if (chglog) chglog.innerHTML = changes.slice(0, 14).map(c =>
      `<div class="cl-row"><code>${esc(c.sha).slice(0, 7)}</code><span class="cl-msg">${esc(c.msg)}</span></div>`).join("");
    if (chgSrc) chgSrc.textContent = changes.length + " commits · live";
    if (liveStatus) { liveStatus.hidden = false; liveText.textContent = "maintained live · " + changes.length + " edits"; }
    const top = changes[0].sha;
    if (first) { headSha = top; con(`<span class="dim">[keeper]</span> changelog synced · <span class="ok">${changes.length} commits</span>`); }
    else if (top !== headSha) { con(`<span class="dim">[keeper]</span> new commit <span class="ok">${esc(top).slice(0,7)}</span> — reloading`); if (liveText) liveText.textContent = "keeper just edited — reloading…"; setTimeout(() => location.reload(), 1800); }
  } catch (_) { if (chgSrc) chgSrc.textContent = "offline"; }
}
