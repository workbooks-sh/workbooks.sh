/* ── LEARN CHASSIS JS — shared by the three concept pages ──────────────────
   Each page declares `window.LEARN = { mix, story }` before this script:
     mix   — the piece's DNA proportions [[color, frac], ...]
     story — terminal lines [[kind, text], ...] (same grammar as the lander) */

/* DNA bars — same shared-hues / different-proportions system as the lander */
function dnaSegs(mix, seed) {
  const segs = [];
  let k = seed;
  mix.forEach(([color, frac]) => {
    const n = frac > 0.3 ? 3 : frac > 0.12 ? 2 : 1;
    for (let j = 0; j < n; j++) segs.push([color, frac / n]);
  });
  for (let i = segs.length - 1; i > 0; i--) {
    k++;
    const j = Math.floor((((Math.sin(k * 127.1) * 43758.5453) % 1) + 1) % 1 * (i + 1));
    [segs[i], segs[j]] = [segs[j], segs[i]];
  }
  return segs.map(([c, w]) => `<i style="width:${(w * 100).toFixed(1)}%;background:${c}"></i>`).join("");
}
document.querySelectorAll("[data-dna]").forEach((el, i) => {
  el.innerHTML = dnaSegs(LEARN.mix, i * 97 + 13);
});

/* TOC scrollspy */
const tocLinks = [...document.querySelectorAll(".ltoc a")];
const sections = tocLinks.map(a => document.querySelector(a.getAttribute("href")));
function spy() {
  let on = 0;
  sections.forEach((s, i) => { if (s && s.getBoundingClientRect().top < 150) on = i; });
  tocLinks.forEach((a, i) => a.classList.toggle("on", i === on));
}
addEventListener("scroll", spy, { passive: true });
spy();

/* terminal storyteller — typed commands, printed output, branded scrollbar.
   Plays once when the block scrolls into view. */
async function playStory(story) {
  const term = document.querySelector(".lterm");
  if (!term) return;
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const thumb = document.querySelector(".lscroll .thumb");
  const syncBar = () => {
    const track = document.querySelector(".lscroll");
    if (!track || !thumb) return;
    const h = track.clientHeight;
    const frac = Math.min(1, term.clientHeight / term.scrollHeight);
    const top = term.scrollHeight > term.clientHeight
      ? (term.scrollTop / (term.scrollHeight - term.clientHeight)) * (h * (1 - frac)) : 0;
    thumb.style.height = Math.max(18, h * frac) + "px";
    thumb.style.top = top + "px";
  };
  term.addEventListener("scroll", syncBar);
  const line = (html, cls) => {
    const d = document.createElement("div");
    d.className = "ln" + (cls ? " " + cls : "");
    d.innerHTML = html;
    term.appendChild(d);
    term.scrollTop = term.scrollHeight;
    syncBar();
    return d;
  };
  syncBar();
  for (const [kind, text] of story) {
    if (kind === "cmd") {
      await sleep(420);
      const d = line(`<span class="ps">$ </span><span class="cmd"></span><span class="caret"></span>`);
      const span = d.querySelector(".cmd");
      for (const ch of text) {
        span.textContent += ch;
        term.scrollTop = term.scrollHeight;
        await sleep(26);
      }
      d.querySelector(".caret").remove();
      await sleep(300);
    } else {
      await sleep(kind === "dim" ? 200 : 300);
      line(text, kind === "out" ? "" : kind);
    }
  }
  line(`<span class="ps">$ </span><span class="caret"></span>`);
}
const tb = document.querySelector(".termblock");
if (tb) {
  new IntersectionObserver((entries, obs) => {
    if (entries[0].isIntersecting) { obs.disconnect(); playStory(LEARN.story); }
  }, { threshold: 0.35 }).observe(tb);
}
