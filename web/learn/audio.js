/* ── the learn-audio player — one source of truth, every lesson page ────────
   Fully-produced narrated episodes (one per lesson; ElevenLabs v3 narration
   + composed music) in a workbooks-branded player. Desktop: a dock in the
   hero. Mobile: a fixed bottom bar that expands into a full-screen player
   with the episode list — jump straight into any other lesson's audio.
   Chapters within an episode are seekable. Markup + styles + behavior live
   HERE; pages just include <script src="audio.js" defer>.                 */
(function () {
  var slug = (location.pathname.match(/learn\/([a-z]+?)(?:\.html)?\/?$/) || [])[1] || "workbook";
  var LS = "wbAudio.v2";

  var css = [
    /* ── shared tokens ── */
    '.ap, .ap * { box-sizing: border-box; font-synthesis: none; }',
    '.ap button { font: inherit; border: 0; background: none; cursor: pointer; color: inherit; padding: 0; }',
    '.ap .pp { width: 40px; height: 40px; border-radius: 50%; background: var(--ink, #121316); color: var(--paper, #f7f6f1);',
    '  display: inline-flex; align-items: center; justify-content: center; flex: 0 0 auto; }',
    '.ap .pp:hover { background: var(--bloom, #13d943); color: var(--ink, #121316); }',
    '.ap .pp svg { width: 15px; height: 15px; display: block; }',
    '.ap .sk svg { width: 17px; height: 17px; display: block; }',
    '.ap .sk { color: var(--ink, #121316); opacity: .85; } .ap .sk:hover { color: var(--bloom, #13d943); opacity: 1; }',
    '.ap .ttl { font: 700 11px/1.5 var(--mono, "JetBrains Mono", monospace); letter-spacing: .04em; text-transform: uppercase;',
    '  color: var(--ink, #121316); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }',
    '.ap .sub { font: 400 10px/1.4 var(--mono, monospace); color: var(--dim, #565b54); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }',
    '.ap .tm { font: 400 10px var(--mono, monospace); color: var(--dim, #565b54); font-variant-numeric: tabular-nums; }',
    '.ap input[type=range] { -webkit-appearance: none; appearance: none; width: 100%; height: 14px; background: transparent; margin: 0; }',
    '.ap input[type=range]::-webkit-slider-runnable-track { height: 4px; border-radius: 2px;',
    '  background: linear-gradient(to right, var(--bloom, #13d943) var(--p, 0%), rgba(18,19,22,.18) var(--p, 0%)); }',
    '.ap input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; width: 12px; height: 12px; border-radius: 50%;',
    '  background: var(--ink, #121316); border: 2px solid var(--paper, #f7f6f1); box-shadow: 0 0 0 1.5px var(--ink, #121316); margin-top: -4px; }',
    '.ap input[type=range]::-moz-range-track { height: 4px; border-radius: 2px; background: rgba(18,19,22,.18); }',
    '.ap input[type=range]::-moz-range-progress { height: 4px; border-radius: 2px; background: var(--bloom, #13d943); }',
    '.ap input[type=range]::-moz-range-thumb { width: 9px; height: 9px; border-radius: 50%; background: var(--ink, #121316); border: 2px solid var(--paper, #f7f6f1); }',
    '.ap .spd { font: 700 10px var(--mono, monospace); letter-spacing: .06em; border: 1.5px solid var(--ink, #121316);',
    '  border-radius: 6px; padding: 4px 7px; color: var(--ink, #121316); }',
    '.ap .spd:hover { background: var(--ink, #121316); color: var(--paper, #f7f6f1); }',

    /* ── desktop dock (in the hero) ── */
    '.apdock { display: flex; align-items: center; gap: 12px; margin-top: 22px; max-width: 560px;',
    '  background: var(--paper, #f7f6f1); border: 2px solid var(--ink, #121316); border-radius: 12px;',
    '  padding: 10px 14px; box-shadow: 4px 4px 0 var(--ink, #121316); position: relative; }',
    '.apdock .mid { flex: 1; min-width: 0; }',
    '.apdock .bar { display: flex; align-items: center; gap: 8px; margin-top: 3px; }',
    '.apdock .bar input { flex: 1; }',
    '.apdock .lst { color: var(--ink, #121316); } .apdock .lst:hover { color: var(--bloom, #13d943); }',
    '.apdock .lst svg { width: 16px; height: 16px; display: block; }',

    /* ── desktop playlist popover ── */
    '.appop { position: absolute; top: calc(100% + 12px); right: -2px; z-index: 30; width: 360px; max-height: 56vh; overflow: auto;',
    '  background: var(--paper, #f7f6f1); border: 2px solid var(--ink, #121316); border-radius: 12px;',
    '  box-shadow: 5px 5px 0 var(--ink, #121316); padding: 10px; display: none; }',
    '.appop.open { display: block; }',

    /* ── playlist (episodes + chapters; shared popover + sheet) ── */
    '.apls .row { display: flex; align-items: center; gap: 10px; width: 100%; text-align: left;',
    '  padding: 10px 8px; border-radius: 8px; }',
    '.apls .row:hover { background: rgba(18,19,22,.06); }',
    '.apls .row.on { background: var(--ink, #121316); }',
    '.apls .row.on .ttl, .apls .row.on .tm, .apls .row.on .sub { color: var(--paper, #f7f6f1); }',
    '.apls .row.on .eq { display: inline-flex; }',
    '.apls .row .swp { width: 18px; height: 18px; border-radius: 5px; flex: 0 0 auto; border: 1.5px solid var(--ink, #121316); }',
    '.apls .row.on .swp { border-color: var(--paper, #f7f6f1); }',
    '.apls .row .ttl { flex: 1; font-size: 10.5px; }',
    '.apls .eq { display: none; gap: 2px; align-items: flex-end; height: 11px; flex: 0 0 auto; }',
    '.apls .eq i { width: 2.5px; background: var(--bloom, #13d943); animation: apeq 1s ease-in-out infinite; }',
    '.apls .eq i:nth-child(1){height:50%} .apls .eq i:nth-child(2){height:100%;animation-delay:.25s} .apls .eq i:nth-child(3){height:70%;animation-delay:.5s}',
    '@keyframes apeq { 0%,100%{transform:scaleY(.4)} 50%{transform:scaleY(1)} }',
    '.ap.paused .eq i, .paused .apls .eq i { animation-play-state: paused; }',
    '.apls .chaps { margin: 2px 0 6px 14px; border-left: 2px solid rgba(18,19,22,.2); }',
    '.apls .chap { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left;',
    '  padding: 6px 8px 6px 12px; border-radius: 0 8px 8px 0; }',
    '.apls .chap:hover { background: rgba(18,19,22,.06); }',
    '.apls .chap .ttl { flex: 1; font-weight: 400; font-size: 10px; text-transform: none; letter-spacing: .02em; }',
    '.apls .chap.on .ttl { font-weight: 700; color: var(--bloom-d, #149157); }',

    /* ── mobile bottom bar ── */
    '.apbar { display: none; position: fixed; left: 10px; right: 10px; bottom: 10px; z-index: 40;',
    '  align-items: center; gap: 11px; background: var(--paper, #f7f6f1); border: 2px solid var(--ink, #121316);',
    '  border-radius: 14px; padding: 9px 12px; box-shadow: 4px 4px 0 var(--ink, #121316);',
    '  padding-bottom: calc(9px + env(safe-area-inset-bottom, 0px) * .4); }',
    '.apbar .mid { flex: 1; min-width: 0; }',
    '.apbar .prog { height: 3px; border-radius: 2px; background: rgba(18,19,22,.15); margin-top: 5px; overflow: hidden; }',
    '.apbar .prog i { display: block; height: 100%; width: 0; background: var(--bloom, #13d943); }',
    '.apbar .exp svg { width: 19px; height: 19px; display: block; }',
    '.apbar .exp { color: var(--ink, #121316); }',

    /* ── mobile full-screen sheet ── */
    '.apsheet { display: none; position: fixed; inset: 0; z-index: 50; background: var(--paper, #f7f6f1); flex-direction: column;',
    '  padding: 18px 20px calc(20px + env(safe-area-inset-bottom, 0px)); overflow: auto; }',
    '.apsheet.open { display: flex; }',
    '.apsheet .top { display: flex; align-items: center; justify-content: space-between; flex: 0 0 auto; }',
    '.apsheet .cls { width: 38px; height: 38px; display: flex; align-items: center; justify-content: center;',
    '  border: 2px solid var(--ink, #121316); border-radius: 10px; color: var(--ink, #121316); }',
    '.apsheet .cls svg { width: 15px; height: 15px; display: block; }',
    '.apsheet .kick { font: 700 10px var(--mono, monospace); letter-spacing: .24em; text-transform: uppercase; color: var(--dim, #565b54); }',
    '.apsheet .art { margin: 18px auto 0; width: min(64vw, 300px); border: 2px solid var(--ink, #121316);',
    '  border-radius: 14px; overflow: hidden; box-shadow: 6px 6px 0 var(--ink, #121316); flex: 0 0 auto; }',
    '.apsheet .art img { display: block; width: 100%; aspect-ratio: 1 / 1; object-fit: cover; }',
    '.apsheet .now { text-align: center; margin-top: 18px; flex: 0 0 auto; }',
    '.apsheet .now .ttl { font-size: 13px; white-space: normal; }',
    '.apsheet .now .sub { margin-top: 4px; }',
    '.apsheet .scrub { margin-top: 14px; flex: 0 0 auto; }',
    '.apsheet .times { display: flex; justify-content: space-between; margin-top: 2px; }',
    '.apsheet .ctl { display: flex; align-items: center; justify-content: center; gap: 34px; margin-top: 12px; flex: 0 0 auto; }',
    '.apsheet .ctl .pp { width: 62px; height: 62px; } .apsheet .ctl .pp svg { width: 22px; height: 22px; }',
    '.apsheet .ctl .sk svg { width: 26px; height: 26px; }',
    '.apsheet .spds { display: flex; justify-content: center; gap: 8px; margin-top: 16px; flex: 0 0 auto; }',
    '.apsheet .spds .spd.on { background: var(--ink, #121316); color: var(--paper, #f7f6f1); }',
    '.apsheet .apls { margin-top: 20px; border-top: 2px solid var(--ink, #121316); padding-top: 6px; }',

    '@media (max-width: 820px) {',
    '  .apdock { display: none; }',
    '  .apbar { display: flex; }',
    '  body { padding-bottom: 84px; }',
    '}',
  ].join("\n");

  var I = {
    play:  '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.5v15l13-7.5z"/></svg>',
    pause: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.5 4.5h4v15h-4zM13.5 4.5h4v15h-4z"/></svg>',
    prev:  '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6 5h2.5v14H6zM20 5.5v13L9.5 12z"/></svg>',
    next:  '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M15.5 5H18v14h-2.5zM4 5.5v13L14.5 12z"/></svg>',
    list:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M4 6.5h16M4 12h16M4 17.5h9"/><circle cx="18.5" cy="17.5" r="1.4" fill="currentColor" stroke="none"/></svg>',
    down:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 9l7 7 7-7"/></svg>',
  };
  var SW = { workbook: "#a8d4f0", nexus: "#aee5c2", toolkit: "#f3c5a3", org: "#f2ddb0", agents: "#9fc4e8", autopoet: "#aee5c2", wbx: "#d9dbd3" };

  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);

  fetch("audio/manifest.json").then(function (r) { return r.json(); }).then(boot)
    .catch(function () { /* no audio yet — pages work without it */ });

  function boot(man) {
    var Q = man.episodes;
    if (!Q || !Q.length) return;
    var cur = Math.max(0, Q.findIndex(function (e) { return e.slug === slug; }));
    var saved = {};
    try { saved = JSON.parse(localStorage.getItem(LS) || "{}"); } catch (e) {}
    var rates = [0.75, 1, 1.25, 1.5, 2];
    var rate = rates.indexOf(saved.rate) >= 0 ? saved.rate : 1;

    var au = new Audio();
    au.preload = "none";

    function el(html) { var d = document.createElement("div"); d.innerHTML = html; return d.firstElementChild; }
    function fmt(s) { s = Math.max(0, Math.round(s || 0)); return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2); }
    function lessonName(e) { return e.title.split("—")[0].trim(); }

    var dock = el(
      '<div class="ap apdock paused" role="region" aria-label="Listen to this lesson">' +
      '<button class="pp" aria-label="Play">' + I.play + "</button>" +
      '<div class="mid"><div class="ttl"></div>' +
      '<div class="bar"><span class="tm cu">0:00</span><input type="range" min="0" max="100" value="0" step="0.1" aria-label="Seek">' +
      '<span class="tm to">–:––</span></div></div>' +
      '<button class="sk pv" aria-label="Previous lesson">' + I.prev + "</button>" +
      '<button class="sk nx" aria-label="Next lesson">' + I.next + "</button>" +
      '<button class="spd">1×</button>' +
      '<button class="lst" aria-label="All lessons">' + I.list + "</button>" +
      '<div class="appop"><div class="apls"></div></div></div>'
    );
    var hero = document.querySelector(".lhero .lcol");
    if (hero) hero.appendChild(dock);

    var bar = el(
      '<div class="ap apbar paused" role="region" aria-label="Audio player">' +
      '<button class="pp" aria-label="Play">' + I.play + "</button>" +
      '<div class="mid"><div class="ttl"></div><div class="prog"><i></i></div></div>' +
      '<button class="exp" aria-label="Open player">' + I.list + "</button></div>"
    );
    document.body.appendChild(bar);

    var sheet = el(
      '<div class="ap apsheet paused" role="dialog" aria-label="Audio player">' +
      '<div class="top"><span class="kick">listening — workbooks</span>' +
      '<button class="cls" aria-label="Close">' + I.down + "</button></div>" +
      '<div class="art"><img alt=""></div>' +
      '<div class="now"><div class="ttl"></div><div class="sub"></div></div>' +
      '<div class="scrub"><input type="range" min="0" max="100" value="0" step="0.1" aria-label="Seek">' +
      '<div class="times"><span class="tm cu">0:00</span><span class="tm to">–:––</span></div></div>' +
      '<div class="ctl"><button class="sk pv" aria-label="Previous lesson">' + I.prev + "</button>" +
      '<button class="pp" aria-label="Play">' + I.play + "</button>" +
      '<button class="sk nx" aria-label="Next lesson">' + I.next + "</button></div>" +
      '<div class="spds"></div><div class="apls"></div></div>'
    );
    document.body.appendChild(sheet);

    var spds = sheet.querySelector(".spds");
    rates.forEach(function (r) {
      var b = el('<button class="spd">' + r + "×</button>");
      b.addEventListener("click", function () { setRate(r); });
      spds.appendChild(b);
    });

    // ── episode list with inline chapters for the active episode ──
    function buildList(host) {
      host.innerHTML = "";
      Q.forEach(function (e, i) {
        var row = el(
          '<button class="row" data-i="' + i + '">' +
          '<span class="swp" style="background:' + (SW[e.slug] || "#ddd") + '"></span>' +
          '<span class="ttl">' + e.title + "</span>" +
          '<span class="eq"><i></i><i></i><i></i></span>' +
          '<span class="tm">' + fmt(e.dur) + "</span></button>"
        );
        row.addEventListener("click", function () { load(i, true); });
        host.appendChild(row);
        if (i === cur && e.chapters && e.chapters.length) {
          var box = el('<div class="chaps"></div>');
          e.chapters.forEach(function (c) {
            var ch = el('<button class="chap" data-t="' + c.t + '"><span class="ttl">' + c.title + '</span><span class="tm">' + fmt(c.t) + "</span></button>");
            ch.addEventListener("click", function () {
              if (!au.src) load(cur, false);
              au.currentTime = c.t;
              au.play();
            });
            box.appendChild(ch);
          });
          host.appendChild(box);
        }
      });
    }
    function rebuildLists() {
      buildList(dock.querySelector(".apls"));
      buildList(sheet.querySelector(".apls"));
    }
    rebuildLists();

    function chapterAt(time) {
      var cs = Q[cur].chapters || [];
      var c = null;
      for (var i = 0; i < cs.length; i++) if (time >= cs[i].t) c = cs[i];
      return c;
    }

    function paint() {
      var e = Q[cur];
      var playing = !au.paused;
      [dock, bar, sheet].forEach(function (n) { n.classList.toggle("paused", !playing); });
      document.querySelectorAll(".ap .pp").forEach(function (b) {
        b.innerHTML = playing ? I.pause : I.play;
        b.setAttribute("aria-label", playing ? "Pause" : "Play");
      });
      dock.querySelector(".ttl").textContent = e.title;
      bar.querySelector(".ttl").textContent = e.title;
      sheet.querySelector(".now .ttl").textContent = e.title;
      var art = sheet.querySelector(".art img");
      if (sheet.classList.contains("open")) art.src = "img/" + e.slug + "-hero.jpg";
      else art.dataset.src = "img/" + e.slug + "-hero.jpg";
      dock.querySelector(".spd").textContent = rate + "×";
      sheet.querySelectorAll(".spds .spd").forEach(function (b) { b.classList.toggle("on", parseFloat(b.textContent) === rate); });
      document.querySelectorAll(".apls .row").forEach(function (r) { r.classList.toggle("on", +r.dataset.i === cur); });
    }

    function tick() {
      var d = au.duration || Q[cur].dur || 0, c = au.currentTime || 0, p = d ? (c / d) * 100 : 0;
      [dock, sheet].forEach(function (n) {
        var r = n.querySelector('input[type=range]');
        if (r && !r.matches(":active")) { r.value = p; r.style.setProperty("--p", p + "%"); }
        n.querySelector(".cu").textContent = fmt(c);
        n.querySelector(".to").textContent = fmt(d);
      });
      bar.querySelector(".prog i").style.width = p + "%";
      // live chapter readout + highlight
      var ch = chapterAt(c);
      sheet.querySelector(".now .sub").textContent = ch ? lessonName(Q[cur]) + " · " + ch.title : lessonName(Q[cur]);
      document.querySelectorAll(".apls .chap").forEach(function (r) {
        r.classList.toggle("on", !!ch && +r.dataset.t === ch.t);
      });
    }

    function save() {
      try { localStorage.setItem(LS, JSON.stringify({ i: cur, t: au.currentTime, rate: rate })); } catch (e) {}
    }

    function load(i, andPlay) {
      var changed = ((i + Q.length) % Q.length) !== cur;
      cur = (i + Q.length) % Q.length;
      au.src = Q[cur].src.replace(/^audio\//, "audio/");
      au.playbackRate = rate;
      if (changed) rebuildLists();
      paint(); tick(); save();
      if (andPlay) au.play();
      if ("mediaSession" in navigator) {
        navigator.mediaSession.metadata = new MediaMetadata({
          title: Q[cur].title,
          artist: "Workbooks — learn",
          artwork: [{ src: location.origin + "/learn/img/" + Q[cur].slug + "-hero.jpg", sizes: "512x512", type: "image/jpeg" }],
        });
      }
    }

    function toggle() { au.paused ? au.play() : au.pause(); }
    function next() { load(cur + 1, !au.paused || au.ended); }
    function prev() { (au.currentTime > 5) ? (au.currentTime = 0) : load(cur - 1, !au.paused); }
    function setRate(r) { rate = r; au.playbackRate = r; paint(); save(); }

    document.querySelectorAll(".ap .pp").forEach(function (b) { b.addEventListener("click", function (e) { e.stopPropagation(); toggle(); }); });
    document.querySelectorAll(".ap .pv").forEach(function (b) { b.addEventListener("click", prev); });
    document.querySelectorAll(".ap .nx").forEach(function (b) { b.addEventListener("click", next); });
    dock.querySelector(".spd").addEventListener("click", function () { setRate(rates[(rates.indexOf(rate) + 1) % rates.length]); });
    dock.querySelector(".lst").addEventListener("click", function (e) { e.stopPropagation(); dock.querySelector(".appop").classList.toggle("open"); });
    document.addEventListener("click", function (e) { if (!dock.contains(e.target)) dock.querySelector(".appop").classList.remove("open"); });
    function openSheet() {
      sheet.classList.add("open");
      document.body.style.overflow = "hidden";
      var art = sheet.querySelector(".art img");
      if (art.dataset.src && art.src.indexOf(art.dataset.src) < 0) art.src = art.dataset.src;
    }
    bar.querySelector(".exp").addEventListener("click", openSheet);
    bar.querySelector(".mid").addEventListener("click", openSheet);
    sheet.querySelector(".cls").addEventListener("click", function () { sheet.classList.remove("open"); document.body.style.overflow = ""; });
    [dock, sheet].forEach(function (n) {
      n.querySelector('input[type=range]').addEventListener("input", function () {
        var d = au.duration || Q[cur].dur || 0;
        au.currentTime = (this.value / 100) * d;
        this.style.setProperty("--p", this.value + "%");
      });
    });

    au.addEventListener("play", paint);
    au.addEventListener("pause", function () { paint(); save(); });
    au.addEventListener("ended", function () { next(); });
    au.addEventListener("timeupdate", tick);
    if ("mediaSession" in navigator) {
      navigator.mediaSession.setActionHandler("play", function () { au.play(); });
      navigator.mediaSession.setActionHandler("pause", function () { au.pause(); });
      navigator.mediaSession.setActionHandler("previoustrack", prev);
      navigator.mediaSession.setActionHandler("nexttrack", next);
    }

    // resume a cross-page listening session; otherwise start at this lesson
    if (typeof saved.i === "number" && Q[saved.i] && saved.t > 1) {
      cur = saved.i;
      load(cur, false);
      au.currentTime = saved.t;
    } else {
      load(cur, false);
    }
  }
})();
