/* ── THE search — one overlay for the whole site ─────────────────────────────
   Mount-free: include this script on any page and you get a search overlay that
   opens on Cmd/Ctrl-K or on a `wb-search-open` custom event (so the nav pill, a
   learn-page search bar, anything can fire it). It loads a static index
   (/search-index.json, built by build-search-index.py) and does substring +
   subsequence (fuzzy) matching, ranked. Keyboard: type to filter, ↑/↓ to move,
   Enter to open, Esc to close. Zero dependencies. Styles live in search.css. */
(function () {
  if (window.__wbSearch) return; // singleton
  window.__wbSearch = true;

  // absolute base: works from any path + the docs domain (cross-site → main site)
  var root = (location.hostname === "docs.workbooks.sh") ? "https://workbooks.sh/" : "/";

  // ── matcher ───────────────────────────────────────────────────────────────
  // score 0 = no match; higher = better. Substring beats subsequence; a hit in
  // the title beats one in the body; an earlier hit beats a later one.
  function score(q, rec) {
    if (!q) return 0;
    var title = (rec.title || "").toLowerCase();
    var sub = (rec.sub || "").toLowerCase();
    var text = (rec.text || "").toLowerCase();
    var best = 0;
    var ti = title.indexOf(q);
    if (ti === 0) best = Math.max(best, 1000);
    else if (ti > 0) best = Math.max(best, 700 - ti);
    if (sub.indexOf(q) >= 0) best = Math.max(best, 360);
    var xi = text.indexOf(q);
    if (xi >= 0) best = Math.max(best, 300 - Math.min(xi, 250));
    if (best) return best;
    // subsequence (fuzzy) fallback on the title only
    var fs = fuzzy(q, title);
    return fs ? fs : 0;
  }

  function fuzzy(q, hay) {
    var qi = 0, prev = -2, run = 0, sc = 0;
    for (var i = 0; i < hay.length && qi < q.length; i++) {
      if (hay[i] === q[qi]) {
        run = i === prev + 1 ? run + 1 : 0;
        sc += 12 + run * 8 + (i === 0 ? 20 : 0);
        prev = i;
        qi++;
      }
    }
    return qi === q.length ? sc : 0;
  }

  // ── build the DOM ───────────────────────────────────────────────────────────
  var overlay, input, list, results = [], active = 0, index = null, loading = false;

  function build() {
    if (!document.getElementById("wb-search-css")) {
      var link = document.createElement("link");
      link.id = "wb-search-css";
      link.rel = "stylesheet";
      link.href = root + "search.css";
      document.head.appendChild(link);
    }
    overlay = document.createElement("div");
    overlay.className = "wbsearch";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", "Site search");
    overlay.innerHTML =
      '<div class="wbsearch-scrim"></div>' +
      '<div class="wbsearch-box">' +
      '  <div class="wbsearch-head">' +
      '    <svg class="wbsearch-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round">' +
      '      <circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></svg>' +
      '    <input class="wbsearch-input" type="text" placeholder="Search lessons & docs…" ' +
      '      autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" aria-label="Search">' +
      '    <kbd class="wbsearch-esc">esc</kbd>' +
      '  </div>' +
      '  <div class="wbsearch-results" role="listbox"></div>' +
      '</div>';
    document.body.appendChild(overlay);
    input = overlay.querySelector(".wbsearch-input");
    list = overlay.querySelector(".wbsearch-results");

    overlay.querySelector(".wbsearch-scrim").addEventListener("click", close);
    overlay.querySelector(".wbsearch-esc").addEventListener("click", close);
    input.addEventListener("input", function () { run(input.value); });
    input.addEventListener("keydown", onKey);
  }

  function loadIndex() {
    if (index || loading) return;
    loading = true;
    fetch(root + "search-index.json")
      .then(function (r) { return r.json(); })
      .then(function (d) { index = (d && d.records) || []; if (overlay && overlay.classList.contains("open")) run(input.value); })
      .catch(function () { index = []; });
  }

  // ── search + render ─────────────────────────────────────────────────────────
  function run(q) {
    q = (q || "").trim().toLowerCase();
    if (!index) { list.innerHTML = '<div class="wbsearch-empty">Loading…</div>'; return; }
    if (!q) {
      // empty query: show a short starter set (lessons first)
      results = index.slice(0, 8);
    } else {
      results = index
        .map(function (rec) { return { rec: rec, s: score(q, rec) }; })
        .filter(function (x) { return x.s > 0; })
        .sort(function (a, b) { return b.s - a.s; })
        .slice(0, 12)
        .map(function (x) { return x.rec; });
    }
    active = 0;
    render(q);
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function render(q) {
    if (!results.length) {
      list.innerHTML = '<div class="wbsearch-empty">No matches' + (q ? ' for "' + esc(q) + '"' : "") + ".</div>";
      return;
    }
    list.innerHTML = results.map(function (rec, i) {
      var tag = rec.kind === "docs" ? "Docs" : "Learn";
      return '<a class="wbsearch-item' + (i === active ? " on" : "") + '" role="option" href="' + esc(rec.url) + '" data-i="' + i + '">' +
        '<span class="wbsearch-tag wbsearch-tag-' + esc(rec.kind) + '">' + tag + "</span>" +
        '<span class="wbsearch-tt"><b>' + esc(rec.title) + "</b>" +
        (rec.sub ? '<small>' + esc(rec.sub) + "</small>" : "") + "</span>" +
        '<svg class="wbsearch-go" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"/><path d="M13 5l7 7-7 7"/></svg>' +
        "</a>";
    }).join("");
    Array.prototype.forEach.call(list.querySelectorAll(".wbsearch-item"), function (el) {
      el.addEventListener("mousemove", function () { setActive(+el.dataset.i); });
    });
  }

  function setActive(i) {
    if (!results.length) return;
    active = (i + results.length) % results.length;
    var items = list.querySelectorAll(".wbsearch-item");
    Array.prototype.forEach.call(items, function (el, j) { el.classList.toggle("on", j === active); });
    var on = items[active];
    if (on) on.scrollIntoView({ block: "nearest" });
  }

  function go() {
    var rec = results[active];
    if (rec) { close(); location.href = rec.url; }
  }

  function onKey(e) {
    if (e.key === "ArrowDown") { e.preventDefault(); setActive(active + 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive(active - 1); }
    else if (e.key === "Enter") { e.preventDefault(); go(); }
    else if (e.key === "Escape") { e.preventDefault(); close(); }
  }

  // ── open / close ────────────────────────────────────────────────────────────
  function open() {
    if (!overlay) build();
    loadIndex();
    overlay.classList.add("open");
    document.documentElement.style.overflow = "hidden";
    input.value = "";
    run("");
    setTimeout(function () { input.focus(); }, 0);
  }
  function close() {
    if (!overlay) return;
    overlay.classList.remove("open");
    document.documentElement.style.overflow = "";
  }

  // ── triggers ──────────────────────────────────────────────────────────────
  window.addEventListener("wb-search-open", open);
  document.addEventListener("keydown", function (e) {
    if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K")) {
      e.preventDefault();
      if (overlay && overlay.classList.contains("open")) close(); else open();
    }
  });
})();
