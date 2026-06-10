// live.js — the page builds itself: a grandiose skeleton "full build" (sections
// stand in as shimmer, then resolve top-down while the inspector streams a build
// log), then the inspector becomes the live dashboard (agent · html · source ·
// the real changelog). The webpage stays a webpage; the inspector holds the meta.

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, r = document) => r.querySelector(s);
const LIVE = location.pathname.startsWith("/live") ? "/live" : "";
const esc = s => (s || "").replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
const wait = ms => new Promise(r => setTimeout(r, ms));

const insp = $("#insp");
const setInsp = on => insp?.setAttribute("data-open", String(on));
const presence = $("#presence"), ptext = $("#p-text");

/* ── the build ──────────────────────────────────────────────────────────── */
const blocks = [...document.querySelectorAll("[data-build]")];
// a human label per block, in document order, for the build log
const labelFor = el =>
  el.closest(".hero") ? "hero" :
  (el.closest("section")?.id || "section");

async function build() {
  if (reduce) { blocks.forEach(b => b.classList.add("built")); afterBuild(); return; }

  blocks.forEach(b => b.classList.add("building"));
  if (ptext) ptext.textContent = "lander-keeper is building this page";

  // open the inspector and stream a build log — the "full build", visible
  setInsp(true);
  const agentPane = $("#pane-agent");
  const log = document.createElement("div"); log.id = "buildlog";
  agentPane?.prepend(log);
  const line = (html) => { const d = document.createElement("div"); d.className = "bl"; d.innerHTML = html; log.appendChild(d); };

  line(`<span class="ok">$</span> wb agent run "compose workbooks.sh"`);
  await wait(650);

  for (const b of blocks) {
    const name = labelFor(b);
    line(`composing <b>${esc(name)}</b> …`);
    await wait(520);
    b.classList.remove("building"); b.classList.add("built");
    log.lastChild.innerHTML = `composing <b>${esc(name)}</b> <span class="ok">✓</span>`;
    await wait(180);
  }
  line(`rendered ${blocks.length} blocks · <span class="ok">live</span>`);
  await wait(700);
  afterBuild(log);
}

function afterBuild(log) {
  if (ptext) { ptext.textContent = "composed just now · maintained live"; presence?.classList.add("settled"); }
  setTimeout(() => presence?.classList.add("fade"), 4500);
  // retire the build log, hand the inspector back to the live dashboard
  setTimeout(() => { log?.remove(); setInsp(false); }, 1400);
  poll(true);
  setInterval(() => poll(false), 30000);
  startMakePrompt();
}
build();

/* ── inspector chrome ───────────────────────────────────────────────────── */
$("#insp-handle")?.addEventListener("click", () => setInsp(insp.getAttribute("data-open") !== "true"));
presence?.addEventListener("click", () => setInsp(true));
document.querySelectorAll(".insp .tab").forEach(t => t.addEventListener("click", () => {
  document.querySelectorAll(".insp .tab").forEach(x => x.classList.remove("on"));
  document.querySelectorAll(".insp .pane").forEach(x => x.classList.remove("on"));
  t.classList.add("on"); $("#pane-" + t.dataset.pane).classList.add("on");
  if (t.dataset.pane === "html" || t.dataset.pane === "source") buildSource();
}));

let srcBuilt = false;
function buildSource() {
  if (srcBuilt) return; srcBuilt = true;
  const raw = "<!doctype html>\n" + document.documentElement.outerHTML;
  const re = /<!--\s*@note\(([\w-]+)\)([\s\S]*?)-->/g;
  const out = []; let last = 0, m, notes = 0;
  while ((m = re.exec(raw))) {
    out.push(`<code>${esc(raw.slice(last, m.index))}</code>`);
    out.push(`<div class="note"><span class="nt">${esc(m[1])}</span>${esc(m[2].trim().replace(/\s+/g, " "))}</div>`);
    last = m.index + m[0].length; notes++;
  }
  out.push(`<code>${esc(raw.slice(last))}</code>`);
  const code = `<div class="src-code">${out.join("")}</div>`;
  const html = $("#pane-html"), srcb = $("#src-body");
  if (html) html.innerHTML = `<div class="src-head">${(raw.length / 1024).toFixed(1)} KB · ${notes} notes — the annotations are for you</div>${code}`;
  if (srcb) srcb.innerHTML = code;
}

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
      await wait(1600);
      for (let k = s.length; k >= 0; k--) { mp.textContent = s.slice(0, k); await wait(22); }
      await wait(350); i++;
    }
  })();
}

/* ── live changelog: inspector + footer status ── */
const clog = $("#chglog"), chgSrc = $("#chg-src");
const liveStatus = $("#live-status"), liveText = $("#live-text");
let headSha = null;
async function poll(first) {
  try {
    const r = await fetch(LIVE + "/_changes", { cache: "no-store" });
    if (!r.ok) return;
    const { changes } = await r.json();
    if (!changes || !changes.length) return;
    if (clog) clog.innerHTML = changes.slice(0, 14).map(c =>
      `<div class="cl-row"><code>${esc(c.sha).slice(0, 7)}</code><span class="cl-msg">${esc(c.msg)}</span></div>`).join("");
    if (chgSrc) chgSrc.textContent = changes.length + " commits · live";
    if (liveStatus) { liveStatus.hidden = false; liveText.textContent = "maintained live · " + changes.length + " edits"; }
    const top = changes[0].sha;
    if (first) headSha = top;
    else if (top !== headSha) { if (liveText) liveText.textContent = "keeper just edited — reloading…"; setTimeout(() => location.reload(), 1800); }
  } catch (_) { if (chgSrc) chgSrc.textContent = "offline"; }
}
