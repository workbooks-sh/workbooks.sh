// live.js — the page presenting itself AS a workbook: a calm composed reveal
// (an agent assembling it, not a terminal), a quiet presence marker, and the
// inspector (agent changelog · the real HTML · the source). No hacker cosplay.

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, r = document) => r.querySelector(s);
const LIVE = location.pathname.startsWith("/live") ? "/live" : "";
const esc = s => (s || "").replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

/* ── composed reveal ─────────────────────────────────────────────────────
   Content rises in as if being placed. Hero composes on load (staggered);
   lower sections reveal on scroll. A presence marker narrates it. */
const reveals = [...document.querySelectorAll("[data-reveal]")];
const presence = $("#presence"), ptext = $("#p-text");
const heroReveals = [...document.querySelectorAll(".hero [data-reveal]")];

if (reduce) {
  reveals.forEach(el => el.classList.add("shown"));
  if (ptext) ptext.textContent = "composed by lander-keeper";
} else {
  document.body.classList.add("reveal-on");
  if (ptext) ptext.textContent = "lander-keeper is composing this page";

  // hero: staggered compose on load
  heroReveals.forEach((el, i) => setTimeout(() => el.classList.add("shown"), 220 + i * 130));
  // when the hero finishes, settle the presence marker
  setTimeout(() => {
    if (ptext) ptext.textContent = "composed just now · maintained live";
    presence?.classList.add("settled");
    setTimeout(() => presence?.classList.add("fade"), 4200);
  }, 260 + heroReveals.length * 130);

  // lower sections: reveal on scroll
  const io = new IntersectionObserver((entries) => {
    entries.forEach(e => {
      if (e.isIntersecting) { e.target.classList.add("shown"); io.unobserve(e.target); }
    });
  }, { rootMargin: "0px 0px -8% 0px", threshold: 0.05 });
  reveals.filter(el => !heroReveals.includes(el)).forEach(el => io.observe(el));
}

/* ── inspector ───────────────────────────────────────────────────────────── */
const insp = $("#insp");
const openInsp = (on) => insp?.setAttribute("data-open", String(on));
$("#insp-handle")?.addEventListener("click", () => openInsp(insp.getAttribute("data-open") !== "true"));
presence?.addEventListener("click", () => openInsp(true));

document.querySelectorAll(".insp .tab").forEach(t => t.addEventListener("click", () => {
  document.querySelectorAll(".insp .tab").forEach(x => x.classList.remove("on"));
  document.querySelectorAll(".insp .pane").forEach(x => x.classList.remove("on"));
  t.classList.add("on");
  $("#pane-" + t.dataset.pane).classList.add("on");
  if (t.dataset.pane === "html" || t.dataset.pane === "source") buildSource();
}));

/* the real HTML / source — this page's own markup, with @note callouts rendered
   as clean educational asides (no terminal styling). */
let srcBuilt = false;
function buildSource() {
  if (srcBuilt) return;
  srcBuilt = true;
  const raw = "<!doctype html>\n" + document.documentElement.outerHTML;
  const re = /<!--\s*@note\(([\w-]+)\)([\s\S]*?)-->/g;
  const out = [];
  let last = 0, m, notes = 0;
  while ((m = re.exec(raw))) {
    out.push(`<code>${esc(raw.slice(last, m.index))}</code>`);
    out.push(`<div class="note"><span class="nt">${esc(m[1])}</span>${esc(m[2].trim().replace(/\s+/g, " "))}</div>`);
    last = m.index + m[0].length; notes++;
  }
  out.push(`<code>${esc(raw.slice(last))}</code>`);
  const body = `<div class="src-head">${(raw.length / 1024).toFixed(1)} KB · ${notes} notes — the annotations are for you</div><div class="src-code">${out.join("")}</div>`;
  const html = $("#pane-html"), srcb = $("#src-body");
  if (html) html.innerHTML = body;
  if (srcb) srcb.innerHTML = `<div class="src-code">${out.join("")}</div>`;
}

/* ── live changelog (the agent's real commits) ──────────────────────────── */
const clog = $("#chglog"), chgSrc = $("#chg-src");
const liveStatus = $("#live-status"), liveText = $("#live-text");
let head = null;
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
    if (first) head = top;
    else if (top !== head) { if (liveText) liveText.textContent = "keeper just edited — reloading…"; setTimeout(() => location.reload(), 1800); }
  } catch (_) { if (chgSrc) chgSrc.textContent = "offline"; }
}
poll(true);
setInterval(() => poll(false), 30000);
