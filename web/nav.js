/* ── THE nav — one source of truth for every page ──────────────────────────
   Markup + styles + behavior live HERE and nowhere else; pages mount it with
   <div id="site-nav"></div><script src="(../)nav.js"></script>. Drift between
   per-page navs is what this file exists to kill. Feature flags bake here. */
(function () {
  var FLAGS = { desktopDownload: false };
  var root = /\/learn\//.test(location.pathname) ? "../" : "";

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
    '.nav .drop .panel .vsep { width: 2px; margin: 6px 10px; flex: 0 0 auto;',
    '  background-image: repeating-linear-gradient(180deg, rgba(18,19,22,.3) 0 4px, transparent 4px 8px); }',
    '.nav .drop .panel .colhead { font: 700 9px var(--mono, monospace); letter-spacing: .22em;',
    '  text-transform: uppercase; color: var(--dim, #565b54); padding: 8px 10px 6px; display: flex; align-items: baseline; gap: 8px; }',
    '.nav .drop .panel .colhead small { font-weight: 400; letter-spacing: .02em; text-transform: none; font-size: 9px; }',
    '.nav .drop .panel a .cat { font: 700 8.5px var(--mono, monospace); letter-spacing: .08em; color: var(--ink, #121316);',
    '  background: var(--swc, #ddd); border-radius: 5px; padding: 3px 6px; flex: 0 0 auto; }',
    '.nav .drop .panel .nbempty { font: 400 10.5px var(--mono, monospace); color: var(--dim, #565b54); padding: 8px 10px; }',
    '.nav .drop .panel .subbody { max-height: 340px; overflow-y: auto; }',
    '.nav .drop .panel a.viewall { justify-content: center; font-size: 10.5px; color: var(--dim, #565b54); }',
    '.nav .drop .panel a.viewall:hover { color: var(--ink, #121316); }',
    '.nav a.gh { display: inline-flex; align-items: center; color: var(--ink, #121316); }',
    '.nav a.gh svg { width: 19px; height: 19px; display: block; }',
    '.nav a.gh:hover { color: var(--bloom, #13d943); }',
    '@media (max-width: 820px) {',
    '  .nav { gap: 14px; padding: 8px 12px; top: 12px; max-width: 94vw; }',
    '  .nav .drop .panel { flex-direction: column; max-height: 70vh; overflow: auto; min-width: 0; width: 88vw; left: 50%; }',
    '  .nav .drop .panel .vsep { width: auto; height: 2px; margin: 8px 6px;',
    '    background-image: repeating-linear-gradient(90deg, rgba(18,19,22,.3) 0 4px, transparent 4px 8px); }',
    '}',
  ].join("\n");

  var WMARK = '<svg viewBox="0 0 113.444 65.6002" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z" fill="currentColor"/></svg>';
  var GH = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>';


  function item(href, sw, name, small) {
    return '<a href="' + root + href + '"><span class="sw" style="background:' + sw[0] + '">' + sw[1] + '</span> ' + name + ' <small>' + small + '</small></a>';
  }

  // lessons come from THE catalog (learn/lessons.json) — the CMS seed.
  var lessonsCol = '<div class="col" data-lessons><div class="colhead">lessons <small>loading…</small></div></div>';
  // hovering a lesson on the left fills this panel with its deep dives
  var subPanel = '<div class="col" data-subpanel><div class="colhead">deep dives <small>hover a lesson</small></div><div class="subbody"></div></div>';

  function lessonRow(l) {
    var icon = l.icon.indexOf("../") === 0 ? root + l.icon.slice(3) : root + "learn/" + l.icon;
    return '<a href="' + root + 'learn/' + l.slug + '">' +
      '<span class="sw" style="background:' + l.color + '"><img src="' + icon + '" alt=""></span> ' +
      l.title + ' <small>' + l.sub + '</small></a>';
  }


  // Docs — stubbed category panel; everything points at the repo until the
  // documentation CMS lands (the categories are the future information
  // architecture, shown early on purpose)
  var REPO = 'https://github.com/workbooks-sh/workbooks.sh';
  var docsCol =
    '<div class="col">' +
    item2(REPO + '#readme', 'Getting started', 'install · first workbook') +
    item2(REPO + '/tree/main/cli', 'wbx CLI', 'verbs · modes · import') +
    item2(REPO + '/tree/main/runtime', 'Engine & deploy', 'nexus · wbx deploy') +
    item2(REPO + '/tree/main/toolkits', 'Toolkits', 'authoring · the lanes') +
    '<div class="sep" aria-hidden="true"></div>' +
    '<a class="viewall" href="' + REPO + '">view all on GitHub → <small>full docs coming</small></a>' +
    '</div>';
  function item2(href, name, small) {
    return '<a href="' + href + '"><span class="sw" style="background:#d9dbd3"><b>¶</b></span> ' + name + ' <small>' + small + '</small></a>';
  }

  var html =
    '<a class="mark" href="' + (root || "") + 'index.html" aria-label="Workbooks">' + WMARK + '</a>' +
    '<div class="drop"><a href="#">Learn</a><div class="panel">' + lessonsCol + '<div class="vsep" aria-hidden="true"></div>' + subPanel + '</div></div>' +
    '<div class="drop"><a href="#">Docs</a><div class="panel">' + docsCol + '</div></div>' +
    '<a class="lnk gh" href="' + REPO + '" aria-label="GitHub">' + GH + '</a>' +
    (FLAGS.desktopDownload ? '<a class="dl" href="' + root + 'index#download">Download</a>' : '');

  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);
  var nav = document.createElement("nav");
  nav.className = "nav";
  nav.innerHTML = html;
  var mount = document.getElementById("site-nav");
  if (mount) mount.replaceWith(nav);

  fetch(root + "learn/lessons.json")
    .then(function (r) { return r.json(); })
    .then(function (cat) {
      var host = nav.querySelector("[data-lessons]");
      if (!host) return;
      var html = "";
      cat.tiers.forEach(function (tier, i) {
        if (i > 0) html += '<div class="sep" aria-hidden="true"></div>';
        html += '<div class="colhead">' + (i === 0 ? "lessons" : "") + ' <small>' + tier.title + "</small></div>";
        tier.lessons.filter(function (l) { return l.status === "live"; }).forEach(function (l) {
          html += lessonRow(l).replace("<a ", '<a data-slug="' + l.slug + '" ');
        });
      });
      host.innerHTML = html;

      var bylSlug = {};
      cat.tiers.forEach(function (t) { t.lessons.forEach(function (l) { bylSlug[l.slug] = l; }); });
      var body = nav.querySelector("[data-subpanel] .subbody");
      var head = nav.querySelector("[data-subpanel] .colhead");

      function subRow(x) {
        var icon = x.icon.indexOf("../") === 0 ? root + x.icon.slice(3) : root + "learn/" + x.icon;
        return '<a href="' + root + 'learn/' + x.slug + '">' +
          '<span class="sw" style="background:' + x.color + '"><img src="' + icon + '" alt=""></span> ' +
          x.title + "</a>";
      }
      function showSubs(slug) {
        var l = bylSlug[slug];
        var subs = (l.sublessons || []).filter(function (x) { return x.status === "live"; });
        head.innerHTML = "deep dives <small>in " + l.title.toLowerCase() + "</small>";
        body.innerHTML = subs.length
          ? subs.map(subRow).join("")
          : '<div class="nbempty">nothing deeper here yet — the shelf grows</div>';
      }
      function showRecent() {
        head.innerHTML = 'deep dives <small>most recent</small>';
        var all = [];
        cat.tiers.forEach(function (t) {
          t.lessons.forEach(function (l) {
            (l.sublessons || []).filter(function (x) { return x.status === "live"; }).forEach(function (x) { all.push(x); });
          });
        });
        all.sort(function (a, b) { return (b.added || "").localeCompare(a.added || ""); });
        // show what fits — the panel scrolls when the shelf outgrows it
        body.innerHTML = all.slice(0, 8).map(subRow).join("") ||
          '<div class="nbempty">deep dives appear here as the shelf grows</div>';
      }
      showRecent();
      host.querySelectorAll("a[data-slug]").forEach(function (a) {
        a.addEventListener("mouseenter", function () { showSubs(a.dataset.slug); });
      });
      nav.querySelector("[data-lessons]").addEventListener("mouseleave", showRecent);
    })
    .catch(function () {});

  nav.querySelectorAll(".drop > a").forEach(function (drop) {
    drop.addEventListener("click", function (e) {
      e.preventDefault();
      var d = drop.parentElement;
      nav.querySelectorAll(".drop.open").forEach(function (o) { if (o !== d) o.classList.remove("open"); });
      d.classList.toggle("open");
    });
  });

})();
