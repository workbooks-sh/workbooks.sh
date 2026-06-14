/* ── THE nav — one source of truth for every page ──────────────────────────
   Markup + styles + behavior live HERE and nowhere else; pages mount it with
   <div id="site-nav"></div><script src="(../)nav.js"></script>. Drift between
   per-page navs is what this file exists to kill. Feature flags bake here. */
(function () {
  var FLAGS = { desktopDownload: false };
  // Absolute base so links work from ANY path (/blog/, /toolkits/, /learn/<slug>)
  // and from the docs domain (cross-site → the main site). Was path-relative,
  // which 404'd Learn/Blog/lessons.json from non-/learn pages.
  var root = (location.hostname === "docs.workbooks.sh") ? "https://workbooks.sh/" : "/";

  var css = [
    '.nav { position: fixed; top: 22px; left: 50%; transform: translateX(-50%); z-index: 10;',
    '  display: flex; align-items: center; gap: 26px;',
    '  background: var(--paper, #f7f6f1); border: 2px solid var(--ink, #121316); border-radius: 10px;',
    '  padding: 10px 16px; box-shadow: 5px 5px 0 var(--ink, #121316); }',
    '.nav .mark { width: 30px; color: var(--ink, #121316); display: flex; }',
    '.nav .mark svg { width: 100%; height: auto; display: block; }',
    '.nav a.lnk, .nav .drop > a { font: 500 12px/1 var(--mono, "JetBrains Mono", monospace);',
    '  letter-spacing: .06em; text-transform: uppercase; color: var(--ink, #121316); text-decoration: none; }',
    '.nav a.lnk:hover, .nav .drop > a:hover { color: var(--bloom, #13d943); }',
    '.nav .dl { font: 700 12px/1 var(--mono, "JetBrains Mono", monospace); letter-spacing: .06em;',
    '  text-transform: uppercase; text-decoration: none; color: var(--paper, #f7f6f1);',
    '  background: var(--ink, #121316); padding: 9px 16px; border-radius: 6px; }',
    '.nav .dl:hover { background: var(--bloom, #13d943); }',
    '.nav .drop { position: relative; }',
    '.nav .drop > a { display: inline-flex; align-items: center; }',
    '.nav .drop > a::after { content: ""; display: inline-block; width: 7px; height: 7px;',
    '  border-right: 2.5px solid currentColor; border-bottom: 2.5px solid currentColor;',
    '  transform: rotate(45deg) translate(-1px, -1px); margin-left: 9px; }',
    '.nav .drop .panel { position: absolute; top: calc(100% + 14px); left: 50%; transform: translateX(-50%);',
    '  display: none; min-width: 240px; background: var(--paper, #f7f6f1);',
    '  border: 2px solid var(--ink, #121316); border-radius: 10px; box-shadow: 5px 5px 0 var(--ink, #121316);',
    '  padding: 8px; z-index: 11; }',
    '.nav .drop .panel::before { content: ""; position: absolute; top: -16px; left: 0; right: 0; height: 16px; }',
    '.nav .drop:hover .panel, .nav .drop:focus-within .panel, .nav .drop.open .panel { display: flex; }',
    '.nav .drop .panel a { display: flex; align-items: center; gap: 10px; text-decoration: none;',
    '  font: 700 11.5px/1 var(--mono, "JetBrains Mono", monospace); letter-spacing: .05em;',
    '  text-transform: uppercase; color: var(--ink, #121316); padding: 9px 10px; border-radius: 7px; }',
    '.nav .drop .panel a:hover { background: rgba(18,19,22,.06); }',
    '.nav .drop .panel a .sw { width: 22px; height: 22px; border-radius: 6px; flex: 0 0 auto;',
    '  display: inline-flex; align-items: center; justify-content: center; }',
    '.nav .drop .panel a .sw img { height: 13px; filter: invert(.92); }',
    '.nav .drop .panel a .sw b { font: 700 13px var(--mono, monospace); color: var(--ink, #121316); }',
    '.nav .drop .panel a small { font-weight: 400; letter-spacing: 0; text-transform: none;',
    '  color: var(--dim, #565b54); margin-left: auto; font-size: 10px; padding-left: 12px; }',
    '.nav .drop .panel .sep { height: 2px; margin: 7px 6px;',
    '  background-image: repeating-linear-gradient(90deg, rgba(18,19,22,.3) 0 4px, transparent 4px 8px); }',
    '.nav .drop .panel .col { display: flex; flex-direction: column; min-width: 230px; }',
    /* Docs panel: a Diátaxis grid — several compact columns of section links */
    '.nav .drop .panel.docs { display: none; min-width: 0; gap: 0; flex-direction: column; padding: 14px; }',
    '.nav .drop:hover .panel.docs, .nav .drop:focus-within .panel.docs, .nav .drop.open .panel.docs { display: flex; }',
    '.nav .drop .panel.docs .grid { display: grid; grid-template-columns: repeat(3, max-content); gap: 4px 40px; align-items: start; }',
    '.nav .drop .panel.docs > .grid > .col { min-width: 0; gap: 10px; }',          /* a grid column may stack 2 groups */
    '.nav .drop .panel.docs .colhead { padding: 10px 10px 4px; }',
    '.nav .drop .panel.docs a { padding: 6px 10px; font-weight: 600; white-space: nowrap; }',  /* literal titles, never wrap */
    '.nav .drop .panel.docs .foot { display: flex; align-items: center; gap: 6px; padding: 4px; margin-top: 4px;',
    '  border-top: 2px solid rgba(18,19,22,.10); }',
    '.nav .drop .panel.docs .foot a { flex: 1; justify-content: center; font-size: 10.5px; color: var(--dim, #565b54);',
    '  text-align: center; }',
    '.nav .drop .panel.docs .foot a:hover { color: var(--ink, #121316); }',
    '.nav .drop .panel.docs .foot a + a { border-left: 2px solid rgba(18,19,22,.10); }',
    /* search trigger — same weight as the GH glyph */
    '.nav button.srch { display: inline-flex; align-items: center; color: var(--ink, #121316); background: none;',
    '  border: 0; padding: 0; cursor: pointer; }',
    '.nav button.srch svg { width: 18px; height: 18px; display: block; }',
    '.nav button.srch:hover { color: var(--bloom, #13d943); }',
    /* Learn column: short noun list, everything on one line (no wrapping) */
    '.nav .drop .panel .learncol { min-width: 340px; }',
    '.nav .drop .panel .learncol a { white-space: nowrap; }',
    '.nav .drop .panel .learncol a small { white-space: nowrap; }',
    '.nav .drop .panel .vsep { width: 2px; margin: 6px 10px; flex: 0 0 auto;',
    '  background-image: repeating-linear-gradient(180deg, rgba(18,19,22,.3) 0 4px, transparent 4px 8px); }',
    '.nav .drop .panel .colhead { font: 700 9px var(--mono, monospace); letter-spacing: .22em;',
    '  text-transform: uppercase; color: var(--dim, #565b54); padding: 8px 10px 6px; display: flex; align-items: baseline; gap: 8px; }',
    '.nav .drop .panel .colhead small { font-weight: 400; letter-spacing: .02em; text-transform: none; font-size: 9px; }',
    '.nav .drop .panel a .cat { font: 700 8.5px var(--mono, monospace); letter-spacing: .08em; color: var(--ink, #121316);',
    '  background: var(--swc, #ddd); border-radius: 5px; padding: 3px 6px; flex: 0 0 auto; }',
    '.nav .drop .panel .nbempty { font: 400 10.5px var(--mono, monospace); color: var(--dim, #565b54); padding: 8px 10px; }',
    '.nav .drop .panel [data-subpanel] { display: flex; flex-direction: column; }',
    '.nav .drop .panel .subbody { flex: 1; min-height: 0; overflow-y: auto; }',
    '.nav .drop .panel a.soon { opacity: .45; cursor: default; }',
    '.nav .drop .panel [data-lessons] a { position: relative; }',
    '.nav .drop .panel [data-lessons] a.on { background: rgba(18,19,22,.07);',
    '  margin-right: -10px; padding-right: 26px; border-radius: 7px; }',
    '.nav .drop .panel [data-lessons] a.on::after { content: ""; position: absolute; right: 9px; top: 50%;',
    '  width: 7px; height: 7px; border-top: 2.5px solid var(--bloom-d, #149157); border-right: 2.5px solid var(--bloom-d, #149157);',
    '  transform: translateY(-50%) rotate(45deg); }',
    '.nav .drop .panel a.soon:hover { background: none; }',
    '.nav .drop .panel a.viewall { justify-content: center; font-size: 10.5px; color: var(--dim, #565b54); }',
    '.nav .drop .panel a.viewall:hover { color: var(--ink, #121316); }',
    '.nav a.gh { display: inline-flex; align-items: center; color: var(--ink, #121316); }',
    '.nav a.gh svg { width: 19px; height: 19px; display: block; }',
    '.nav a.gh:hover { color: var(--bloom, #13d943); }',
    /* hamburger — hidden on desktop, the only control on mobile */
    '.nav .burger { display: none; width: 28px; height: 20px; flex-direction: column;',
    '  justify-content: center; gap: 5px; background: none; border: 0; padding: 0; cursor: pointer; margin-left: auto; }',
    '.nav .burger span { display: block; height: 2.5px; border-radius: 2px; background: var(--ink, #121316);',
    '  transition: transform .22s ease, opacity .18s ease; }',
    '.nav.menu-open .burger span:nth-child(1) { transform: translateY(7.5px) rotate(45deg); }',
    '.nav.menu-open .burger span:nth-child(2) { opacity: 0; }',
    '.nav.menu-open .burger span:nth-child(3) { transform: translateY(-7.5px) rotate(-45deg); }',
    /* ── MOBILE: the pill becomes a bar (logo + burger); tapping the burger drops
       a full-width stacked sheet. Dropdowns become tap-accordions; the hover-only
       deep-dives drilldown is replaced by a flat, always-visible list. ── */
    '@media (max-width: 820px) {',
    '  .nav { left: 12px; right: 12px; transform: none; max-width: none; width: auto; top: 12px;',
    '    flex-wrap: wrap; align-items: center; gap: 0 12px; padding: 11px 15px; }',
    '  .nav .mark { width: 26px; }',
    '  .nav .burger { display: flex; }',
    '  .nav > .drop, .nav > a.gh, .nav > a.dl, .nav > a.toolkits, .nav > button.srch { display: none; }',
    '  .nav.menu-open { row-gap: 2px; max-height: calc(100dvh - 24px); overflow-y: auto; -webkit-overflow-scrolling: touch; }',
    '  .nav.menu-open > .drop { display: block; width: 100%; border-top: 2px solid rgba(18,19,22,.10); margin-top: 8px; padding-top: 2px; }',
    '  .nav.menu-open > a.toolkits { display: block; width: 100%; box-sizing: border-box;',
    '    border-top: 2px solid rgba(18,19,22,.10); margin-top: 8px; padding: 14px 4px; font-size: 13px; }',
    '  .nav.menu-open > button.srch { display: inline-flex; width: 100%; justify-content: flex-start;',
    '    align-items: center; gap: 12px; padding: 14px 4px; color: var(--ink, #121316);',
    '    font: 500 13px/1 var(--mono, "JetBrains Mono", monospace);',
    '    letter-spacing: .06em; text-transform: uppercase;',
    '    border-top: 2px solid rgba(18,19,22,.10); margin-top: 8px; }',
    '  .nav.menu-open > button.srch .i { display: inline-flex; }',
    '  .nav.menu-open > button.srch .srch-label { display: inline !important; }',
    '  .nav.menu-open > a.gh { display: inline-flex; width: 100%; padding: 14px 4px 4px; }',
    '  .nav .drop .panel.docs .grid { grid-template-columns: 1fr; }',
    '  .nav .drop .panel.docs .foot { flex-direction: column; align-items: stretch; }',
    '  .nav .drop .panel.docs .foot a + a { border-left: 0; }',
    '  .nav.menu-open > a.dl { display: inline-flex; width: 100%; justify-content: center; margin-top: 10px; }',
    '  .nav .drop { position: static; }',
    '  .nav .drop > a { width: 100%; box-sizing: border-box; justify-content: space-between;',
    '    padding: 14px 4px; font-size: 13px; }',
    '  .nav .drop > a::after { margin-left: 0; transition: transform .2s; }',
    '  .nav .drop.open > a::after { transform: rotate(225deg) translate(-2px, -2px); }',
    '  .nav .drop .panel { position: static; transform: none; left: auto; top: auto; display: none;',
    '    width: 100%; min-width: 0; border: 0; border-radius: 0; box-shadow: none; background: none;',
    '    padding: 0 0 10px; max-height: none; overflow: visible; }',
    '  .nav .drop.open .panel { display: flex; flex-direction: column; }',
    '  .nav .drop .panel::before { display: none; }',
    '  .nav .drop .panel .vsep { display: none; }',
    '  .nav .drop .panel .col, .nav .drop .panel [data-subpanel] { min-width: 0; width: 100%; }',
    '  .nav .drop .panel a { padding: 13px 10px; font-size: 12.5px; }',
    '  .nav .drop .panel a .sw { width: 26px; height: 26px; }',
    '  .nav .drop .panel [data-lessons] a.on { margin-right: 0; padding-right: 10px; background: none; }',
    '  .nav .drop .panel [data-lessons] a.on::after { display: none; }',
    '  .nav .drop .panel .subbody { overflow: visible; }',
    '  .nav .drop .panel .colhead { padding-top: 12px; }',
    '}',
  ].join("\n");

  var WMARK = '<svg viewBox="0 0 113.444 65.6002" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z" fill="currentColor"/></svg>';
  var GH = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>';
  var SEARCH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="7"/><path d="M21 21l-5.2-5.2"/></svg>';


  function item(href, sw, name, small) {
    return '<a href="' + root + href + '"><span class="sw" style="background:' + sw[0] + '">' + sw[1] + '</span> ' + name + ' <small>' + small + '</small></a>';
  }

  // Docs — the real Diátaxis tree from web/docs/site.org, rendered as a
  // multi-column panel pointing at docs.workbooks.sh/<path>. Each column is one
  // top-level section; the rows are the key pages under it.
  var REPO = 'https://github.com/workbooks-sh/workbooks.sh';
  var DOCS = 'https://docs.workbooks.sh/';
  function dlink(path, name, small) {
    return '<a href="' + DOCS + path + '">' + name +
      (small ? ' <small>' + small + '</small>' : '') + '</a>';
  }
  function dcol(head, rows) {
    return '<div class="col"><div class="colhead">' + head + '</div>' + rows.join('') + '</div>';
  }
  // Deliberate 3-column docs menu: clear literal titles, no subtext, no wrapping.
  // Toolkits live in their own marketplace (the Toolkits nav link), not here.
  var docsGrid =
    '<div class="grid">' +
    '<div class="col">' +
      dcol('Get started', [
        dlink('start/install', 'Install WBX'),
        dlink('start/your-first-workbook', 'Your first workbook'),
        dlink('start/first-toolkit', 'Your first toolkit'),
      ]) +
      dcol('Concepts', [
        dlink('concepts/what-is-a-toolkit', 'What is a toolkit'),
        dlink('concepts/two-surfaces', 'Workbooks & toolkits'),
        dlink('concepts/exec-shapes', 'The six shapes'),
        dlink('concepts/the-dock', 'The Dock & capabilities'),
        dlink('concepts/isolation', 'Isolation tiers'),
      ]) +
    '</div>' +
    dcol('Guides', [
      dlink('build/pick-a-shape', 'Pick a shape'),
      dlink('build/dock-sdk', 'Use the Dock SDK'),
      dlink('build/languages', 'Language lanes'),
      dlink('run/invoke', 'Invoke a toolkit'),
      dlink('deploy/local', 'Deploy locally'),
      dlink('deploy/cloud', 'Deploy to the cloud'),
    ]) +
    '<div class="col">' +
      dcol('Reference', [
        dlink('reference/cli', 'wbx CLI'),
        dlink('reference/runtime', 'Runtime API'),
        dlink('reference/manifest', 'Manifest fields'),
        dlink('reference/caps', 'Dock capabilities'),
        dlink('reference/sdk', 'Dock SDK'),
      ]) +
      dcol('Status', [
        dlink('maturity/index', 'Capability matrix'),
        dlink('deploy/release-layers', 'Release layers'),
      ]) +
    '</div>' +
    '</div>' +
    '<div class="foot">' +
    '<a href="' + DOCS + '">All docs →</a>' +
    '<a href="' + REPO + '">Source on GitHub →</a>' +
    '</div>';

  // Learn — short noun list from lessons.json (the concepts + the constructs),
  // Learning Center link at the bottom. Populated by the fetch below. The old
  // per-lesson deep-dives drilldown is gone.
  var learnCol = '<div class="col learncol" data-learn><div class="colhead">the concepts</div></div>';

  var html =
    '<a class="mark" href="' + (root || "") + 'index.html" aria-label="Workbooks">' + WMARK + '</a>' +
    '<div class="drop"><a href="' + root + 'learn/index.html">Learn</a><div class="panel">' + learnCol + '</div></div>' +
    '<div class="drop"><a href="' + DOCS + '">Docs</a><div class="panel docs">' + docsGrid + '</div></div>' +
    '<a class="lnk toolkits" href="' + DOCS + 'toolkits/index">Toolkits</a>' +
    '<a class="lnk" href="' + root + 'blog">Blog</a>' +
    '<button class="srch" aria-label="Search"><span class="i" aria-hidden="true">' + SEARCH + '</span><span class="srch-label" style="display:none">Search</span></button>' +
    '<a class="lnk gh" href="' + REPO + '" aria-label="GitHub">' + GH + '</a>' +
    (FLAGS.desktopDownload ? '<a class="dl" href="' + root + 'index#download">Download</a>' : '') +
    '<button class="burger" aria-label="Menu" aria-expanded="false"><span></span><span></span><span></span></button>';

  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);
  var nav = document.createElement("nav");
  nav.className = "nav";
  nav.innerHTML = html;
  var mount = document.getElementById("site-nav");
  if (mount) mount.replaceWith(nav);

  // Populate the Learn dropdown from lessons.json: the concepts + the
  // constructs (short noun labels), then a Learning Center link at the bottom.
  fetch(root + "learn/lessons.json")
    .then(function (r) { return r.json(); })
    .then(function (cat) {
      var host = nav.querySelector("[data-learn]");
      if (!host) return;
      function row(l) {
        var icon = l.icon.indexOf("../") === 0 ? root + l.icon.slice(3) : root + "learn/" + l.icon;
        return '<a href="' + root + 'learn/' + l.slug + '">' +
          '<span class="sw" style="background:' + l.color + '"><img src="' + icon + '" alt=""></span> ' +
          l.title + ' <small>' + (l.sub || "") + '</small></a>';
      }
      var html = "";
      cat.tiers.forEach(function (t) {
        html += '<div class="colhead">' + t.title + '</div>';
        t.lessons.forEach(function (l) { html += row(l); });
      });
      html += '<div class="sep" aria-hidden="true"></div>';
      html += '<a class="viewall" href="' + root + 'learn/index.html">Learning Center <small>the full course</small></a>';
      host.innerHTML = html;
    })
    .catch(function () {
      var host = nav.querySelector("[data-learn]");
      if (host) host.innerHTML = '<a class="viewall" href="' + root + 'learn/index.html">Learning Center</a>';
    });

  nav.querySelectorAll(".drop > a").forEach(function (drop) {
    drop.addEventListener("click", function (e) {
      e.preventDefault();
      var d = drop.parentElement;
      nav.querySelectorAll(".drop.open").forEach(function (o) { if (o !== d) o.classList.remove("open"); });
      d.classList.toggle("open");
    });
  });

  // search trigger — fire the event the search overlay listens for, and close
  // Self-load the search overlay assets (absolute) so EVERY page with the nav has
  // working search — not just the learn pages that include search.js directly.
  if (!document.querySelector('link[data-wb-search]')) {
    var scss = document.createElement("link");
    scss.rel = "stylesheet"; scss.href = root + "search.css"; scss.setAttribute("data-wb-search", "1");
    document.head.appendChild(scss);
  }
  if (!window.__wbSearchLoaded && !document.querySelector('script[data-wb-search]')) {
    var sjs = document.createElement("script");
    sjs.src = root + "search.js?v=2"; sjs.defer = true; sjs.setAttribute("data-wb-search", "1");
    document.body.appendChild(sjs);
  }

  // the mobile sheet so the overlay isn't behind it.
  var srch = nav.querySelector("button.srch");
  if (srch) srch.addEventListener("click", function () {
    nav.classList.remove("menu-open");
    var b = nav.querySelector(".burger");
    if (b) b.setAttribute("aria-expanded", "false");
    window.dispatchEvent(new CustomEvent("wb-search-open"));
  });

  // mobile: the burger opens the stacked sheet
  var burger = nav.querySelector(".burger");
  if (burger) burger.addEventListener("click", function () {
    var open = nav.classList.toggle("menu-open");
    burger.setAttribute("aria-expanded", open ? "true" : "false");
    if (!open) nav.querySelectorAll(".drop.open").forEach(function (o) { o.classList.remove("open"); });
  });
  // tapping outside the open menu closes it
  document.addEventListener("click", function (e) {
    if (nav.classList.contains("menu-open") && !nav.contains(e.target)) {
      nav.classList.remove("menu-open");
      if (burger) burger.setAttribute("aria-expanded", "false");
    }
  });

})();

/* ── THE bubble — Groothan's display word, rendered as real SVG outline ───────
   The duo lockup's middle line wears a thick ink ring around a solid fill.
   CSS -webkit-text-stroke + a text-shadow ring approximated this but broke on
   Safari/iOS (stroke renders centered-and-clipped, the shadow ring leaks). An
   SVG <text> with paint-order:stroke draws a TRUE outline that is pixel-identical
   across browsers and scales with the glyph (fixed stroke-to-letter ratio) — so
   the ring never breaks and never drifts with the viewport. One enhancer, every
   page (nav.js is the universal include); zero per-page markup. */
(function () {
  var SVGNS = "http://www.w3.org/2000/svg";
  var S = 100; // internal user-unit font size; the SVG is then sized in em so it
  //            renders the word at EXACTLY the element's real (clamp) font-size.
  function enhance(el) {
    if (el.getAttribute("data-bubbled")) return;
    var word = (el.textContent || "").trim();
    if (!word) return;
    var cs = getComputedStyle(el);
    if (cs.textTransform === "uppercase") word = word.toUpperCase();
    else if (cs.textTransform === "lowercase") word = word.toLowerCase();
    var fill = (cs.getPropertyValue("--bub-fill") || cs.color || "#fff").trim();
    var ink = (cs.getPropertyValue("--ink") || "#121316").trim();
    var ratio = parseFloat(cs.getPropertyValue("--bub-stroke")) || 5.4; // outer ring, % of em
    var ls = parseFloat(cs.letterSpacing);
    var fs = parseFloat(cs.fontSize) || S;

    var svg = document.createElementNS(SVGNS, "svg");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    var txt = document.createElementNS(SVGNS, "text");
    txt.setAttribute("x", "0"); txt.setAttribute("y", "0");
    txt.setAttribute("dominant-baseline", "alphabetic");
    txt.style.cssText = "font-family:" + cs.fontFamily + ";font-weight:" + cs.fontWeight +
      ";font-style:" + cs.fontStyle + ";font-size:" + S + "px;letter-spacing:" +
      (ls ? (ls / fs * S) + "px" : "normal");
    txt.setAttribute("fill", fill);
    txt.setAttribute("stroke", ink);
    txt.setAttribute("stroke-width", (ratio / 100 * S * 2).toFixed(2)); // *2: paint-order shows the outer half
    txt.setAttribute("stroke-linejoin", "round");
    txt.setAttribute("paint-order", "stroke");
    txt.textContent = word;
    svg.appendChild(txt);

    svg.style.cssText = "display:block;visibility:hidden;position:absolute;overflow:visible";
    el.appendChild(svg);
    var bb; try { bb = txt.getBBox(); } catch (e) { el.removeChild(svg); return; }
    var pad = ratio / 100 * S; // keep the ring inside the box
    var vbw = bb.width + pad * 2, vbh = bb.height + pad * 2;
    svg.setAttribute("viewBox", (bb.x - pad) + " " + (bb.y - pad) + " " + vbw + " " + vbh);
    // em sizing → 1 user unit = (fs/S)px, so the glyphs land at the real font size
    var centered = cs.textAlign === "center";
    svg.style.cssText = "display:block;overflow:visible;width:" + (vbw / S).toFixed(3) +
      "em;height:" + (vbh / S).toFixed(3) + "em;margin:" + (centered ? "0 auto" : "0");
    // swap the live text for the SVG, but keep the word for a11y + copy
    el.setAttribute("aria-label", word);
    el.setAttribute("role", "text");
    var sr = document.createElement("span");
    sr.textContent = word;
    sr.style.cssText = "position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap";
    el.childNodes.forEach && Array.prototype.slice.call(el.childNodes).forEach(function (n) {
      if (n !== svg) el.removeChild(n);
    });
    el.insertBefore(sr, svg);
    el.setAttribute("data-bubbled", "1");
  }
  function run() {
    document.querySelectorAll(".lhero h1 .bub, .lockup .jl.bub, [data-bub]").forEach(enhance);
  }
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(run);
  else if (document.readyState !== "loading") run();
  else document.addEventListener("DOMContentLoaded", run);
})();
