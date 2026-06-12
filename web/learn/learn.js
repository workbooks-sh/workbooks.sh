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

/* ── the page renders from its own record ──────────────────────────────────
   Every learn page carries an org spec (script#workbook-spec) — its CMS
   record. The chrome derives from it at runtime: hero lockup + kicker + chip
   from the spec's properties, the TOC from the actual sections, the read
   time from the actual words. Edit the record, the page follows. */
(function () {
  var el = document.getElementById("workbook-spec");
  if (!el) return;
  var org = el.textContent;
  var props = {};
  org.replace(/:([A-Z0-9]+):[ \t]+(\S[^\n]*)/g, function (_, k, v) { props[k] = v.trim(); });

  /* hero from the record */
  var kick = document.querySelector(".lhero .kicker");
  if (kick && props.NN && props.KICKER)
    kick.innerHTML = "learn / " + props.NN + " — <b>" + props.KICKER + "</b>";
  var h1 = document.querySelector(".lhero h1");
  if (h1 && props.TITLE1 && props.TITLE2 && props.TITLE3)
    h1.innerHTML =
      '<span class="ln">' + props.TITLE1 + '</span>' +
      '<span class="ln bub">' + props.TITLE2 + '</span>' +
      '<span class="ln">' + props.TITLE3 + '</span>';
  var chip = document.querySelector(".lhero .meta .on");
  if (chip && props.CHIP) chip.textContent = props.CHIP;

  /* read time from the actual article */
  var article = document.querySelector("article");
  var mins = document.querySelector(".lhero .meta span:not(.on)");
  if (article && mins) {
    var words = article.textContent.trim().split(/\s+/).length;
    mins.textContent = Math.max(1, Math.round(words / 210)) + " min read";
  }

  /* TOC from the sections that actually exist */
  var toc = document.querySelector(".ltoc");
  if (toc && article) {
    var links = [];
    article.querySelectorAll("section[id]").forEach(function (sec) {
      var h = sec.querySelector("h2");
      if (h) {
        var label = h.textContent.replace(/\s+/g, " ").trim().toLowerCase();
        if (label.length > 30) label = label.slice(0, 29).replace(/\s+\S*$/, "") + "…";
        links.push('<a href="#' + sec.id + '">' + label + "</a>");
      }
    });
    if (links.length)
      toc.innerHTML = '<div class="t">on this page</div>\n' + links.join("\n");
  }
})();

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

/* ── reading state, remembered ──────────────────────────────────────────────
   Scroll past a section and its TOC entry flips to done — state persists in
   this browser per page, like task states in the page's own record. */
(function () {
  var slug = (location.pathname.match(/([a-z-]+)\.html/) || [])[1] || "page";
  var KEY = "wb-read-" + slug;
  var read;
  try { read = new Set(JSON.parse(localStorage.getItem(KEY) || "[]")); }
  catch (e) { return; }
  var secs = Array.prototype.slice.call(document.querySelectorAll("article section[id]"));
  function paint() {
    document.querySelectorAll(".ltoc a").forEach(function (a) {
      a.classList.toggle("done", read.has(a.getAttribute("href").slice(1)));
    });
  }
  function check() {
    var changed = false;
    secs.forEach(function (sec) {
      if (!read.has(sec.id) && sec.getBoundingClientRect().bottom < innerHeight * 0.5) {
        read.add(sec.id); changed = true;
      }
    });
    if (changed) {
      try { localStorage.setItem(KEY, JSON.stringify(Array.from(read))); } catch (e) {}
      paint();
    }
  }
  addEventListener("scroll", check, { passive: true });
  paint(); check();
})();
