/* ── the notebook engine — org in, runnable page out ────────────────────────
   A notebook is a real .org file (notebooks/<id>.org) rendered client-side:
   prose becomes the page, and every `#+begin_src js` block becomes an
   EDITABLE CELL with a run button — output appears beneath it, cells share
   one scope (`nb`), top to bottom, like any notebook you've ever met.
   No server, no engine: the whole thing runs in the open page, which is
   itself the point being demonstrated.                                     */
(function () {
  var id = new URLSearchParams(location.search).get("nb") || "loops";
  var V = "3"; // bump to invalidate cached notebook assets

  // the REAL org kernel (runtime/kernel compiled to wasm) — org cells are
  // parsed canonically, not by lookalike regexes
  var oqlReady = (function () {
    function glue(instance) {
      var ex = instance.exports, enc = new TextEncoder(), dec = new TextDecoder();
      function call(name, str) {
        var b = enc.encode(str);
        var p = ex.oql_alloc(b.length);
        new Uint8Array(ex.memory.buffer, p, b.length).set(b);
        var packed = ex[name](p, b.length);
        var op = Number(packed >> 32n), ol = Number(packed & 0xffffffffn);
        var out = dec.decode(new Uint8Array(ex.memory.buffer, op, ol));
        ex.oql_dealloc(p, b.length);
        ex.oql_dealloc(op, ol);
        return out;
      }
      return {
        headlines: function (s) { return JSON.parse(call("oql_parse_headlines", s)); },
        validate: function (s) { return JSON.parse(call("oql_validate", s)); },
        tanglePlan: function (s) { return JSON.parse(call("oql_tangle_plan", s)); },
        render: function (s) { return call("oql_render", s); },
      };
    }
    return fetch("oql.wasm?v=" + V)
      .then(function (r) { return r.arrayBuffer(); })
      .then(function (buf) { return WebAssembly.instantiate(buf, {}); })
      .then(function (r) { return glue(r.instance); })
      .catch(function () { return null; });
  })();

  var css = [
    '.nb-cell { border: 1.5px solid rgba(18,19,22,.3); border-radius: 10px; margin: 20px 0; overflow: hidden; background: #fff; }',
    '.nb-cell .head { display: flex; align-items: center; gap: 10px; padding: 8px 14px;',
    '  border-bottom: 1px solid rgba(18,19,22,.15); }',
    '.nb-cell.org textarea { background: #fcfbf6; }',
    '.nb-cell .tabs { display: flex; gap: 2px; margin-left: auto; }',
    '.nb-cell .tabs button { font: 700 9.5px var(--mono, monospace); letter-spacing: .08em; text-transform: uppercase;',
    '  border: 1.5px solid rgba(18,19,22,.3); background: #fff; color: rgba(18,19,22,.55); padding: 4px 10px; cursor: pointer; }',
    '.nb-cell .tabs button:first-child { border-radius: 6px 0 0 6px; }',
    '.nb-cell .tabs button:last-child { border-radius: 0 6px 6px 0; margin-left: -1.5px; }',
    '.nb-cell .tabs button.on { background: var(--ink, #121316); border-color: var(--ink, #121316); color: #fff; }',
    '.nb-cell .duo { display: grid; grid-template-columns: 1fr 1fr; }',
    '.nb-cell .duo .pane + .pane { border-left: 1px dashed rgba(18,19,22,.25); }',
    '.nb-cell .duo .pt { font: 700 9px var(--mono, monospace); letter-spacing: .2em; text-transform: uppercase;',
    '  color: rgba(18,19,22,.4); padding: 8px 16px 0; }',
    '@media (max-width: 820px) { .nb-cell .duo { grid-template-columns: 1fr; }',
    '  .nb-cell .duo .pane + .pane { border-left: 0; border-top: 1px dashed rgba(18,19,22,.25); } }',
    '.nb-doc { display: none; padding: 10px 20px 16px; font-size: 13px; line-height: 1.85; }',
    '.nb-doc.show { display: block; }',
    '.nb-doc, .nb-doc * { font-family: var(--mono, "JetBrains Mono", monospace); }',
    '.nb-doc h1, .nb-doc h2, .nb-doc h3, .nb-doc h4 { font-size: 13px; font-weight: 700; letter-spacing: .02em;',
    '  text-transform: none; margin: 12px 0 4px; border: 0; padding: 0; color: var(--ink, #121316); background: none; box-shadow: none; }',
    '.nb-doc h1:first-child, .nb-doc h2:first-child { margin-top: 0; }',
    '.nb-doc p { margin: 6px 0; } .nb-doc ul { margin: 6px 0; padding-left: 22px; }',
    '.nb-doc .nb-check { margin-right: 9px; }',
    '.nb-doc .nb-check input { width: 15px; height: 15px; accent-color: var(--bloom-d, #149157); cursor: pointer; vertical-align: -2px; }',
    '.nb-doc h1.done, .nb-doc h2.done, .nb-doc h3.done { color: rgba(18,19,22,.45); text-decoration: line-through; text-decoration-thickness: 1.5px; }',
    '.nb-changes { display: none; border-top: 1px dashed rgba(18,19,22,.25); padding: 8px 16px;',
    '  font: 400 10.5px/1.8 var(--mono, monospace); color: var(--dim, #565b54); }',
    '.nb-changes.show { display: block; }',
    '.nb-changes b { color: var(--bloom-d, #149157); font-weight: 700; }',
    '.nb-cell .head .n { font: 700 10px var(--mono, monospace); letter-spacing: .12em; text-transform: uppercase; color: rgba(18,19,22,.7); }',
    '.nb-cell .head .lang { font: 400 10px var(--mono, monospace); color: rgba(18,19,22,.45); }',
    '.nb-cell .head button, .nb-action > button { margin-left: auto; font: 700 10px var(--mono, monospace); letter-spacing: .08em;',
    '  text-transform: uppercase; border: 1.5px solid var(--ink, #121316); border-radius: 7px; background: var(--ink, #121316);',
    '  color: #fff; padding: 6px 13px; cursor: pointer; }',
    '.nb-cell .head button:hover, .nb-action > button:hover { background: var(--bloom, #13d943); border-color: var(--bloom, #13d943); color: var(--ink, #121316); }',
    '.nb-cell .head button.ran { background: var(--bloom, #13d943); border-color: var(--bloom, #13d943); color: var(--ink, #121316); }',
    '.nb-action { border: 1.5px solid rgba(18,19,22,.3); border-radius: 10px; margin: 20px 0; background: #fff; overflow: hidden; }',
    '.nb-action .row { display: flex; align-items: center; gap: 12px; padding: 10px 14px; flex-wrap: wrap; }',
    '.nb-action .row > button { margin-left: 0; }',
    '.nb-action details { margin-left: auto; }',
    '.nb-action summary { font: 400 10px var(--mono, monospace); color: rgba(18,19,22,.5); cursor: pointer; list-style: none; }',
    '.nb-action summary:hover { color: var(--ink, #121316); }',
    '.nb-action details pre { font: 400 11px/1.7 var(--mono, monospace); background: #fcfbf6; border-top: 1px solid rgba(18,19,22,.15);',
    '  padding: 12px 16px; margin: 0; overflow-x: auto; white-space: pre; }',
    '.nb-cell textarea { display: block; width: 100%; box-sizing: border-box; border: 0; resize: none; padding: 14px 16px;',
    '  font: 400 12px/1.7 var(--mono, monospace); color: var(--ink, #121316); background: #fff;',
    '  outline: none; white-space: pre; overflow-x: auto; overflow-y: hidden; }',
    '.nb-out { display: none; border-top: 1px dashed rgba(18,19,22,.3); background: #f6f6f0; color: #2c2e31;',
    '  font: 400 11.5px/1.8 var(--mono, monospace); padding: 12px 16px; white-space: pre-wrap; max-height: 320px; overflow: auto; }',
    '.nb-out.show { display: block; }',
    '.nb-out .err { color: #b3261e; }',
    '.nb-out .val { color: #0d7a3f; }',
    '.nb-step { display: flex; align-items: baseline; gap: 14px; margin: 44px 0 6px;',
    '  border-bottom: 1.5px solid rgba(18,19,22,.5); padding-bottom: 10px; }',
    '.nb-step span { font: 700 12px var(--mono, monospace); color: rgba(18,19,22,.55); flex: 0 0 auto; }',
    '.nb-step h2 { margin: 0; border: 0; padding: 0; font-size: clamp(20px, 2.6vw, 28px); }',
    '.nb-runall { font: 700 11px var(--mono, monospace); letter-spacing: .08em; text-transform: uppercase;',
    '  border: 1.5px solid var(--ink, #121316); border-radius: 8px; background: var(--bloom, #13d943); color: var(--ink, #121316);',
    '  padding: 9px 16px; cursor: pointer; margin: 6px 0 10px; }',
    '.nb-runall:hover { filter: brightness(1.05); }',
    '.nb-runbar { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }',
    '.nb-runbar small { font: 400 10.5px var(--mono, monospace); color: var(--dim, #565b54); }',
    '.nb-src { background: #fff; border: 1.5px solid rgba(18,19,22,.3); border-radius: 10px; padding: 14px 16px;',
    '  font: 400 12px/1.7 var(--mono, monospace); overflow-x: auto; margin: 18px 0; white-space: pre; }',
    '.nb-recipe { background: #121316; color: #e8eae3; border-radius: 14px; margin: 34px 0 10px; padding: 18px 20px;',
    '  box-shadow: 5px 5px 0 rgba(18,19,22,.35); }',
    '.nb-recipe .rh { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }',
    '.nb-recipe .rh b { font: 700 11px var(--mono, monospace); letter-spacing: .2em; text-transform: uppercase; color: var(--bloom, #13d943); }',
    '.nb-recipe .rh small { font: 400 10.5px var(--mono, monospace); color: #9ba095; }',
    '.nb-recipe pre { white-space: pre-wrap; font: 400 11.5px/1.8 var(--mono, monospace); color: #c9cec3;',
    '  background: rgba(255,255,255,.05); border: 1px dashed rgba(255,255,255,.25); border-radius: 9px;',
    '  padding: 12px 14px; margin: 12px 0; max-height: 300px; overflow: auto; }',
    '.nb-recipe .acts { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }',
    '.nb-recipe .acts button, .nb-recipe .acts a { font: 700 10px var(--mono, monospace); letter-spacing: .1em;',
    '  text-transform: uppercase; border: 2px solid var(--bloom, #13d943); border-radius: 7px; background: var(--bloom, #13d943);',
    '  color: #121316; padding: 7px 13px; cursor: pointer; text-decoration: none; display: inline-block; }',
    '.nb-recipe .acts a.ghost { background: transparent; color: #e8eae3; border-color: rgba(255,255,255,.4); }',
    '.nb-recipe .acts a.ghost:hover, .nb-recipe .acts button:hover { border-color: #fff; }',
    '.nb-recipe .aud { font: 400 10px/1.8 var(--mono, monospace); color: #9ba095; margin-top: 12px; }',
    '.nb-recipe .aud b { color: #c9cec3; font-weight: 700; }',
  ].join("\n");
  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);

  // ── a small, honest org renderer (the subset notebooks use) ──────────────
  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function inline(s) {
    return esc(s)
      .replace(/\[\[([^\]]+)\]\[([^\]]+)\]\]/g, '<a href="$1">$2</a>')
      .replace(/=([^=\n]+)=/g, "<code>$1</code>")
      .replace(/(^|\s)\*([^*\n]+)\*(?=[\s,.;:!?]|$)/g, "$1<b>$2</b>")
      .replace(/(^|\s)\/([^/\n]+)\/(?=[\s,.;:!?]|$)/g, "$1<i>$2</i>");
  }

  function render(org) {
    var meta = {}, body = [], cells = [];
    var lines = org.split("\n");
    var i = 0, para = [], list = null, steps = 0;

    function flushPara() {
      if (para.length) { body.push("<p>" + inline(para.join(" ")) + "</p>"); para = []; }
    }
    function flushList() {
      if (list) { body.push("<ul>" + list.map(function (x) { return "<li>" + inline(x) + "</li>"; }).join("") + "</ul>"); list = null; }
    }

    while (i < lines.length) {
      var l = lines[i];
      var kw = l.match(/^#\+(\w[\w-]*):\s*(.*)$/);
      if (kw && !meta[kw[1].toUpperCase()]) { meta[kw[1].toUpperCase()] = kw[2]; i++; continue; }

      if (/^#\+begin_recipe/i.test(l)) {
        flushPara(); flushList();
        var rlines = [];
        i++;
        while (i < lines.length && !/^#\+end_recipe/i.test(lines[i])) { rlines.push(lines[i]); i++; }
        i++;
        var prompt = rlines.join("\n").trim();
        var raw = "notebooks/" + id + ".org";
        body.push(
          '<div class="nb-recipe">' +
          '<div class="rh"><b>the recipe</b><small>everything above, as a prompt your agent can implement</small></div>' +
          '<pre data-recipe-text>' + esc(prompt) + "</pre>" +
          '<div class="acts">' +
          '<button type="button" data-copy-recipe>copy prompt</button>' +
          '<a class="ghost" href="' + raw + '" target="_blank">raw org source ↗</a>' +
          "</div>" +
          '<div class="aud"><b>non-technical?</b> copy the prompt into your agent and press enter. ' +
          '<b>building?</b> the raw org is the spec — cells are the reference implementation. ' +
          '<b>agent?</b> fetch <code>' + location.origin + "/learn/" + raw + "</code> and follow it.</div>" +
          "</div>"
        );
        continue;
      }

      var src = l.match(/^#\+begin_src\s+(\w+)(.*)$/i);
      if (src) {
        flushPara(); flushList();
        var lang = src[1].toLowerCase(), args = src[2];
        var named = (args.match(/:name\s+(\S+)/) || [])[1];
        var code = [];
        i++;
        while (i < lines.length && !/^#\+end_src/i.test(lines[i])) { code.push(lines[i]); i++; }
        i++;
        if (lang === "org" && named) {
          code = code.map(function (cl) { return cl.replace(/^(\s*),([*#])/, "$1$2"); });
          // an ORG cell. With :view doc it's source + living document side
          // by side (two-way); without, just the source — most don't need more
          var withDoc = /:view\s+doc/.test(args);
          body.push(
            '<div class="nb-cell org' + (withDoc ? " docview" : "") + '" data-org="' + named + '">' +
            '<div class="head"><span class="n">' + named + "</span><span class=\"lang\">" +
            (withDoc ? "org — edit the source, the document follows; tick the document, the source follows" : "org · edit me") + "</span></div>" +
            (withDoc
              ? '<div class="duo">' +
                '<div class="pane"><div class="pt">source</div><textarea spellcheck="false">' + esc(code.join("\n").trim()) + "</textarea></div>" +
                '<div class="pane"><div class="pt">document</div><div class="nb-doc show"></div></div>' +
                "</div>"
              : '<textarea spellcheck="false">' + esc(code.join("\n").trim()) + "</textarea>") +
            '<div class="nb-changes"></div></div>'
          );
        } else if (lang === "js" && /:action\s/.test(args)) {
          // an ACTION: the engine runs it; the code is a disclosure, not the page
          var label = (args.match(/:action\s+(.+)$/) || [, "run"])[1].trim();
          var n = cells.length;
          cells.push(code.join("\n"));
          body.push(
            '<div class="nb-action" data-cell="' + n + '">' +
            '<div class="row"><button type="button" data-run="' + n + '">' + esc(label) + '</button>' +
            '<details><summary>view implementation</summary><pre>' + esc(code.join("\n")) + "</pre></details></div>" +
            '<div class="nb-out"></div></div>'
          );
        } else if (lang === "js" && !/:norun/.test(args)) {
          var n = cells.length;
          cells.push(code.join("\n"));
          body.push(
            '<div class="nb-cell" data-cell="' + n + '">' +
            '<div class="head"><span class="n">code</span><span class="lang">js · editable</span>' +
            '<button type="button" data-run="' + n + '">run</button></div>' +
            '<textarea spellcheck="false">' + esc(code.join("\n")) + "</textarea>" +
            '<div class="nb-out"></div></div>'
          );
        } else {
          body.push('<pre class="nb-src">' + esc(code.join("\n")) + "</pre>");
        }
        continue;
      }

      var h = l.match(/^(\*+)\s+(.*)$/);
      if (h) {
        flushPara(); flushList();
        if (h[1].length === 1) {
          steps++;
          body.push(
            '<div class="nb-step"><span>' + (steps < 10 ? "0" + steps : steps) + "</span><h2>" + inline(h[2]) + "</h2></div>"
          );
        } else {
          var lvl = Math.min(h[1].length + 1, 4);
          body.push("<h" + lvl + ">" + inline(h[2]) + "</h" + lvl + ">");
        }
        i++; continue;
      }
      var li = l.match(/^\s*-\s+(.*)$/);
      if (li) { flushPara(); list = list || []; list.push(li[1]); i++; continue; }
      if (!l.trim()) { flushPara(); flushList(); i++; continue; }
      flushPara.toString(); // no-op; keep linters calm
      para.push(l.trim());
      i++;
    }
    flushPara(); flushList();
    return { meta: meta, html: body.join("\n"), cells: cells };
  }

  // ── the runner: shared scope, captured output ─────────────────────────────
  // narrate a change between two org strings in words people understand
  function describeChange(oql, before, after) {
    if (!oql) return [];
    var a = oql.headlines(before), b = oql.headlines(after);
    var byTitle = function (rows) {
      var m = {};
      rows.forEach(function (r) { m[r.title] = r; });
      return m;
    };
    var am = byTitle(a), bm = byTitle(b), out = [];
    b.forEach(function (r) {
      if (!am[r.title]) out.push("added: " + r.title);
      else if (am[r.title].state !== r.state) {
        if (r.state === "DONE") out.push("checked off: " + r.title);
        else if (r.state === "TODO" && am[r.title].state === "DONE") out.push("reopened: " + r.title);
        else out.push("state of " + r.title + ": " + (am[r.title].state || "none") + " to " + (r.state || "none"));
      }
    });
    a.forEach(function (r) { if (!bm[r.title]) out.push("removed: " + r.title); });
    return out;
  }

  function wireOrgCells(article, oqlReady) {
    article.querySelectorAll(".nb-cell.org").forEach(function (cell) {
      var ta = cell.querySelector("textarea");
      var doc = cell.querySelector(".nb-doc");
      var changes = cell.querySelector(".nb-changes");

      function renderDoc(oql) {
        if (!doc) return;
        if (!oql) { doc.innerHTML = "<p>(document view needs the kernel — showing source)</p>"; return; }
        doc.innerHTML = oql.render(ta.value);
        var rows = oql.headlines(ta.value);
        var heads = doc.querySelectorAll("h1,h2,h3,h4,h5,h6");
        heads.forEach(function (h, i) {
          var row = rows[i];
          if (!row || !row.state) return;
          var lab = document.createElement("label");
          lab.className = "nb-check";
          var cb = document.createElement("input");
          cb.type = "checkbox";
          cb.checked = row.state === "DONE";
          cb.dataset.title = row.title;
          cb.dataset.state = row.state;
          lab.appendChild(cb);
          h.insertBefore(lab, h.firstChild);
          h.classList.toggle("done", row.state === "DONE");
        });
      }

      function note(lines) {
        if (!lines.length) return;
        changes.classList.add("show");
        lines.forEach(function (l) {
          var d = document.createElement("div");
          d.innerHTML = "<b>change</b> — " + l;
          changes.appendChild(d);
        });
        while (changes.children.length > 4) changes.removeChild(changes.firstChild);
      }

      cell._set = function (value, oql) {
        var before = ta.value;
        ta.value = value;
        ta.style.height = "auto";
        ta.style.height = ta.scrollHeight + 2 + "px";
        var lines = describeChange(oql, before, value);
        note(lines);
        renderDoc(oql);
        return lines;
      };

      // checkbox in the document flips the SOURCE — the org is the state
      if (doc) doc.addEventListener("change", function (e) {
        var cb = e.target;
        if (cb.type !== "checkbox") return;
        oqlReady.then(function (oql) {
          var from = cb.dataset.state + " " + cb.dataset.title;
          var to = (cb.checked ? "DONE" : "TODO") + " " + cb.dataset.title;
          cell._set(ta.value.replace(from, to), oql);
        });
      });

      // live re-render while editing source (cheap debounce)
      var t = null;
      ta.addEventListener("input", function () {
        clearTimeout(t);
        t = setTimeout(function () { oqlReady.then(renderDoc); }, 300);
      });

      if (doc) oqlReady.then(renderDoc);
    });
  }

  function makeRunner(article, cellSrc) {
    var scope = {};
    function orgAccessor() {
      scope.org = function (name, value) {
        var cell = article.querySelector('[data-org="' + name + '"]');
        if (!cell) throw new Error('no org cell named "' + name + '"');
        var ta = cell.querySelector("textarea");
        if (value !== undefined) {
          var lines = cell._set ? cell._set(value, scope.oql) : (ta.value = value, []);
          scope.lastChange = lines;
        }
        return ta.value;
      };
    }
    orgAccessor();
    function runCell(n) {
      var cell = article.querySelector('[data-cell="' + n + '"]');
      if (!cell) return Promise.resolve();
      return oqlReady.then(function (oql) {
        scope.oql = oql;
        runCellSync(n, cell);
      });
    }
    function runCellSync(n, cell) {
      var out = cell.querySelector(".nb-out");
      var btn = cell.querySelector("button");
      var ta = cell.querySelector("textarea");
      var code = ta ? ta.value : cellSrc[n];
      out.innerHTML = "";
      out.classList.add("show");
      var print = function () {
        var line = document.createElement("div");
        line.textContent = Array.prototype.map.call(arguments, function (a) {
          return typeof a === "object" ? JSON.stringify(a, null, 1) : String(a);
        }).join(" ");
        out.appendChild(line);
        out.scrollTop = out.scrollHeight;
      };
      try {
        var fn = new Function("nb", "out", "print", '"use strict";\n' + code);
        var ret = fn(scope, print, print);
        if (ret !== undefined) {
          var v = document.createElement("div");
          v.className = "val";
          v.textContent = "result: " + (typeof ret === "object" ? JSON.stringify(ret, null, 1) : String(ret));
          out.appendChild(v);
        }
        if (!out.childNodes.length) print("(ran clean — no output)");
        btn.classList.add("ran");
        if (!cell.classList.contains("nb-action")) btn.textContent = "run again";
      } catch (e) {
        var err = document.createElement("div");
        err.className = "err";
        err.textContent = String(e);
        out.appendChild(err);
      }
    }
    article.addEventListener("click", function (e) {
      var b = e.target.closest("[data-run]");
      if (b) runCell(+b.dataset.run);
      var seq = null;
      var cp = e.target.closest("[data-copy-recipe]");
      if (cp) {
        var txt = article.querySelector("[data-recipe-text]").textContent;
        navigator.clipboard.writeText(txt).then(function () {
          cp.textContent = "copied ✓";
          setTimeout(function () { cp.textContent = "copy prompt"; }, 1600);
        });
      }
      if (e.target.closest(".nb-runall")) {
        scope = {}; // fresh top-to-bottom run
        orgAccessor();
        seq = Promise.resolve();
        article.querySelectorAll("[data-cell]").forEach(function (c) {
          seq = seq.then(function () { return runCell(+c.dataset.cell); });
        });
      }
    });
  }

  fetch("notebooks/" + id + ".org?v=" + V, { cache: "no-cache" })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
    .then(function (org) {
      var doc = render(org);
      document.title = (doc.meta.TITLE || id) + " — notebook — Workbooks";
      var kicker = document.querySelector("[data-nb-kicker]");
      var h1 = document.querySelector("[data-nb-title]");
      var dek = document.querySelector("[data-nb-dek]");
      if (kicker) kicker.innerHTML = "notebook — <b>" + (doc.meta.CATEGORY || "examples") + "</b>";
      if (h1) h1.textContent = doc.meta.TITLE || id;
      if (dek) dek.textContent = doc.meta.DEK || "";
      var article = document.querySelector("[data-nb-body]");
      var nCells = doc.cells.length;
      article.innerHTML =
        (nCells ? '<div class="nb-runbar"><button type="button" class="nb-runall">run the whole notebook</button>' +
          '<small>executes all ' + nCells + ' code cells, top to bottom — or run each as you read</small></div>' : "") + doc.html;
      // cells size themselves to their code — no hidden lines, no buried handle
      function grow(ta) {
        ta.style.height = "auto";
        ta.style.height = ta.scrollHeight + 2 + "px";
      }
      article.querySelectorAll("textarea").forEach(function (ta) {
        grow(ta);
        ta.addEventListener("input", function () { grow(ta); });
      });
      wireOrgCells(article, oqlReady);
      makeRunner(article, doc.cells);
    })
    .catch(function (e) {
      var article = document.querySelector("[data-nb-body]");
      if (article) article.innerHTML = "<p>Couldn't load this notebook (" + esc(String(e)) + "). <a href='notebooks.html'>Back to the shelf.</a></p>";
    });
})();
