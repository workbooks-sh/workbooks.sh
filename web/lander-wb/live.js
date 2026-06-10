// live.js — the page as a live workbook: composed reveal of the tiles, the
// agent's real changelog (in its tile + the inspector), a typing make-prompt,
// and the inspector (agent · the real HTML · source). Calm, no terminal cosplay.

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, r = document) => r.querySelector(s);
const LIVE = location.pathname.startsWith("/live") ? "/live" : "";
const esc = s => (s || "").replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

/* ── composed reveal — tiles place themselves in ── */
const reveals = [...document.querySelectorAll("[data-reveal]")];
const presence = $("#presence"), ptext = $("#p-text");
if (reduce) {
  reveals.forEach(el => el.classList.add("shown"));
  if (ptext) ptext.textContent = "composed by lander-keeper";
} else {
  document.body.classList.add("reveal-on");
  if (ptext) ptext.textContent = "lander-keeper is composing this page";
  // stagger whatever is in view at load; reveal the rest on scroll
  const vh = innerHeight;
  let above = reveals.filter(el => el.getBoundingClientRect().top < vh * 0.95);
  above.forEach((el, i) => setTimeout(() => el.classList.add("shown"), 200 + i * 110));
  setTimeout(() => {
    if (ptext) ptext.textContent = "composed just now · maintained live";
    presence?.classList.add("settled");
    setTimeout(() => presence?.classList.add("fade"), 4200);
  }, 260 + above.length * 110);
  const io = new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add("shown"); io.unobserve(e.target); }
  }), { rootMargin: "0px 0px -6% 0px", threshold: 0.04 });
  reveals.filter(el => !above.includes(el)).forEach(el => io.observe(el));
}

/* ── inspector ── */
const insp = $("#insp");
const openInsp = on => insp?.setAttribute("data-open", String(on));
$("#insp-handle")?.addEventListener("click", () => openInsp(insp.getAttribute("data-open") !== "true"));
$("#agent-inspect")?.addEventListener("click", () => openInsp(true));
presence?.addEventListener("click", () => openInsp(true));
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
const mp = $("#mp-text");
if (mp && !reduce) {
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
} else if (mp) { mp.textContent = "a reading list with covers"; }
function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

/* ── live changelog: agent tile feed + inspector + footer status ── */
const feed = $("#agent-feed"), clog = $("#chglog"), chgSrc = $("#chg-src");
const liveStatus = $("#live-status"), liveText = $("#live-text");
let headSha = null;
async function poll(first) {
  try {
    const r = await fetch(LIVE + "/_changes", { cache: "no-store" });
    if (!r.ok) return;
    const { changes } = await r.json();
    if (!changes || !changes.length) return;
    if (feed) feed.innerHTML = changes.slice(0, 5).map(c =>
      `<div class="af-row"><span class="af-sha">${esc(c.sha).slice(0, 7)}</span><span class="af-msg">${esc(c.msg)}</span></div>`).join("");
    if (clog) clog.innerHTML = changes.slice(0, 14).map(c =>
      `<div class="cl-row"><code>${esc(c.sha).slice(0, 7)}</code><span class="cl-msg">${esc(c.msg)}</span></div>`).join("");
    if (chgSrc) chgSrc.textContent = changes.length + " commits · live";
    if (liveStatus) { liveStatus.hidden = false; liveText.textContent = "maintained live · " + changes.length + " edits"; }
    const top = changes[0].sha;
    if (first) headSha = top;
    else if (top !== headSha) { if (liveText) liveText.textContent = "keeper just edited — reloading…"; setTimeout(() => location.reload(), 1800); }
  } catch (_) { if (chgSrc) chgSrc.textContent = "offline"; }
}
poll(true);
setInterval(() => poll(false), 30000);
