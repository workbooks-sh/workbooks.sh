/* ── nbcells — runnable org, mountable in any page ──────────────────────────
   Not a page template: a small component library. A page authors its own
   layout and drops in mounts where a live moment earns its place:

     <pre data-nb-org="plan" data-view="doc">…org…</pre>   an org cell
     <pre data-nb-action="label">…js…</pre>                an action button

   Org cells are parsed by the REAL kernel (oql.wasm — the same parser the
   engine runs), actions are hidden implementations behind a button, and
   the optional document view is two-way: tick a checkbox, the source flips.
   Shared scope across a page's actions: nb.org(name[, value]), nb.oql.    */
(function () {
  var css = [
    '.nbc, .nbc * { box-sizing: border-box; }',
    '.nbc { border: 1.5px solid rgba(18,19,22,.3); border-radius: 10px; margin: 20px 0; background: #fff; overflow: hidden; }',
    '.nbc .head { display: flex; align-items: center; gap: 10px; padding: 8px 14px; border-bottom: 1px solid rgba(18,19,22,.15); }',
    '.nbc .head .n { font: 700 10px var(--mono, monospace); letter-spacing: .12em; text-transform: uppercase; color: rgba(18,19,22,.7); }',
    '.nbc .head .lang { font: 400 10px var(--mono, monospace); color: rgba(18,19,22,.45); }',
    '.nbc textarea { display: block; width: 100%; border: 0; resize: none; padding: 13px 16px; background: #fcfbf6;',
    '  font: 400 12px/1.7 var(--mono, monospace); color: var(--ink, #121316); outline: none; white-space: pre; overflow-x: auto; overflow-y: hidden; }',
    '.nbc .duo { display: grid; grid-template-columns: 1fr 1fr; }',
    '.nbc .duo .pane + .pane { border-left: 1px dashed rgba(18,19,22,.25); }',
    '.nbc .duo .pt { font: 700 9px var(--mono, monospace); letter-spacing: .2em; text-transform: uppercase; color: rgba(18,19,22,.4); padding: 8px 16px 0; }',
    '@media (max-width: 820px) { .nbc .duo { grid-template-columns: 1fr; }',
    '  .nbc .duo .pane + .pane { border-left: 0; border-top: 1px dashed rgba(18,19,22,.25); } }',
    '.nbc .doc { padding: 10px 20px 16px; font-size: 12.5px; line-height: 1.85; }',
    '.nbc .doc, .nbc .doc * { font-family: var(--mono, monospace); }',
    '.nbc .doc h1, .nbc .doc h2, .nbc .doc h3 { font: 700 12.5px var(--mono, monospace); letter-spacing: .02em;',
    '  text-transform: none; margin: 12px 0 4px; border: 0; padding: 0; color: var(--ink, #121316); background: none; }',
    '.nbc .doc h1:first-child { margin-top: 0; }',
    '.nbc .doc p { margin: 6px 0; } .nbc .doc ul { margin: 6px 0; padding-left: 22px; }',
    '.nbc .doc .ck { margin-right: 9px; }',
    '.nbc .doc .ck input { width: 14px; height: 14px; accent-color: var(--bloom-d, #149157); cursor: pointer; vertical-align: -2px; }',
    '.nbc .doc .done { color: rgba(18,19,22,.45); text-decoration: line-through; }',
    '.nbc .row { display: flex; align-items: center; gap: 12px; padding: 10px 14px; flex-wrap: wrap; }',
    '.nbc .row > button { font: 700 10px var(--mono, monospace); letter-spacing: .08em; text-transform: uppercase;',
    '  border: 1.5px solid var(--ink, #121316); border-radius: 7px; background: var(--ink, #121316); color: #fff; padding: 6px 13px; cursor: pointer; }',
    '.nbc .row > button:hover { background: var(--bloom, #13d943); border-color: var(--bloom, #13d943); color: var(--ink, #121316); }',
    '.nbc details { margin-left: auto; }',
    '.nbc summary { font: 400 10px var(--mono, monospace); color: rgba(18,19,22,.5); cursor: pointer; list-style: none; }',
    '.nbc summary:hover { color: var(--ink, #121316); }',
    '.nbc details pre { font: 400 11px/1.7 var(--mono, monospace); background: #fcfbf6; border-top: 1px solid rgba(18,19,22,.15);',
    '  padding: 12px 16px; margin: 0; overflow-x: auto; white-space: pre; }',
    '.nbc .out { display: none; border-top: 1px dashed rgba(18,19,22,.3); background: #f6f6f0; color: #2c2e31;',
    '  font: 400 11.5px/1.8 var(--mono, monospace); padding: 12px 16px; white-space: pre-wrap; max-height: 300px; overflow: auto; }',
    '.nbc .out.show { display: block; }',
    '.nbc .out .err { color: #b3261e; }',
    '.nbc .changes { display: none; border-top: 1px dashed rgba(18,19,22,.25); padding: 8px 16px;',
    '  font: 400 10.5px/1.8 var(--mono, monospace); color: var(--dim, #565b54); }',
    '.nbc .changes.show { display: block; }',
    '.nbc .changes b { color: var(--bloom-d, #149157); }',
  ].join("\n");
  var style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);

  // ── the real kernel ──
  var oqlReady = fetch("oql.wasm?v=4")
    .then(function (r) { return r.arrayBuffer(); })
    .then(function (buf) { return WebAssembly.instantiate(buf, {}); })
    .then(function (r) {
      var ex = r.instance.exports, enc = new TextEncoder(), dec = new TextDecoder();
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
    })
    .catch(function () { return null; });

  var scope = {};
  function grow(ta) { ta.style.height = "auto"; ta.style.height = ta.scrollHeight + 2 + "px"; }
  function dedent(t) {
    var lines = t.replace(/^\n+|\s+$/g, "").split("\n");
    var pad = Math.min.apply(null, lines.filter(function (l) { return l.trim(); }).map(function (l) { return l.match(/^\s*/)[0].length; }));
    return lines.map(function (l) { return l.slice(pad); }).join("\n");
  }

  function describeChange(oql, before, after) {
    if (!oql) return [];
    var byT = function (rows) { var m = {}; rows.forEach(function (r) { m[r.title] = r; }); return m; };
    var am = byT(oql.headlines(before)), bm = byT(oql.headlines(after)), out = [];
    Object.keys(bm).forEach(function (t) {
      if (!am[t]) out.push("added: " + t);
      else if (am[t].state !== bm[t].state) out.push((bm[t].state === "DONE" ? "checked off: " : "reopened: ") + t);
    });
    Object.keys(am).forEach(function (t) { if (!bm[t]) out.push("removed: " + t); });
    return out;
  }

  // ── org cells ──
  document.querySelectorAll("[data-nb-org]").forEach(function (mount) {
    var name = mount.dataset.nbOrg;
    var withDoc = mount.dataset.view === "doc";
    var src = dedent(mount.textContent);
    var cell = document.createElement("div");
    cell.className = "nbc org";
    cell.dataset.org = name;
    cell.innerHTML =
      '<div class="head"><span class="n">' + name + '</span><span class="lang">' +
      (withDoc ? "org — edit the source, the document follows; tick the document, the source follows" : "org · edit me") +
      "</span></div>" +
      (withDoc
        ? '<div class="duo"><div class="pane"><div class="pt">source</div><textarea spellcheck="false"></textarea></div>' +
          '<div class="pane"><div class="pt">document</div><div class="doc"></div></div></div>'
        : '<textarea spellcheck="false"></textarea>') +
      '<div class="changes"></div>';
    mount.replaceWith(cell);
    var ta = cell.querySelector("textarea");
    var doc = cell.querySelector(".doc");
    var changes = cell.querySelector(".changes");
    ta.value = src;
    requestAnimationFrame(function () { grow(ta); });
    ta.addEventListener("input", function () {
      grow(ta);
      if (doc) { clearTimeout(cell._t); cell._t = setTimeout(function () { oqlReady.then(renderDoc); }, 300); }
    });

    function renderDoc(oql) {
      if (!doc || !oql) return;
      doc.innerHTML = oql.render(ta.value);
      var rows = oql.headlines(ta.value);
      doc.querySelectorAll("h1,h2,h3,h4,h5,h6").forEach(function (h, i) {
        var row = rows[i];
        if (!row || !row.state) return;
        var lab = document.createElement("label");
        lab.className = "ck";
        lab.innerHTML = '<input type="checkbox" data-title="' + row.title.replace(/"/g, "&quot;") + '" data-state="' + row.state + '"' + (row.state === "DONE" ? " checked" : "") + ">";
        h.insertBefore(lab, h.firstChild);
        h.classList.toggle("done", row.state === "DONE");
      });
    }
    if (doc) {
      oqlReady.then(renderDoc);
      doc.addEventListener("change", function (e) {
        var cb = e.target;
        if (cb.type !== "checkbox") return;
        oqlReady.then(function (oql) {
          cell._set(ta.value.replace(cb.dataset.state + " " + cb.dataset.title, (cb.checked ? "DONE" : "TODO") + " " + cb.dataset.title), oql);
        });
      });
    }
    cell._set = function (value, oql) {
      var lines = describeChange(oql, ta.value, value);
      ta.value = value;
      grow(ta);
      if (doc) renderDoc(oql);
      if (lines.length) {
        changes.classList.add("show");
        lines.forEach(function (l) {
          var d = document.createElement("div");
          d.innerHTML = "<b>change</b> — " + l;
          changes.appendChild(d);
        });
        while (changes.children.length > 4) changes.removeChild(changes.firstChild);
      }
      return lines;
    };
  });

  scope.org = function (name, value) {
    var cell = document.querySelector('.nbc[data-org="' + name + '"]');
    if (!cell) throw new Error('no org cell named "' + name + '"');
    if (value !== undefined) cell._set(value, scope.oql);
    return cell.querySelector("textarea").value;
  };

  // ── actions ──
  document.querySelectorAll("[data-nb-action]").forEach(function (mount) {
    var label = mount.dataset.nbAction;
    var code = dedent(mount.textContent);
    var cell = document.createElement("div");
    cell.className = "nbc action";
    cell.innerHTML =
      '<div class="row"><button type="button">' + label + "</button>" +
      '<details><summary>view implementation</summary><pre></pre></details></div><div class="out"></div>';
    cell.querySelector("pre").textContent = code;
    mount.replaceWith(cell);
    var out = cell.querySelector(".out");
    cell.querySelector("button").addEventListener("click", function () {
      oqlReady.then(function (oql) {
        scope.oql = oql;
        out.innerHTML = "";
        out.classList.add("show");
        var print = function () {
          var line = document.createElement("div");
          line.textContent = Array.prototype.map.call(arguments, function (a) {
            return typeof a === "object" ? JSON.stringify(a, null, 1) : String(a);
          }).join(" ");
          out.appendChild(line);
        };
        try {
          var ret = new Function("nb", "print", '"use strict";\n' + code)(scope, print);
          if (ret !== undefined) print("result:", ret);
          if (!out.childNodes.length) print("(ran clean)");
        } catch (e) {
          var err = document.createElement("div");
          err.className = "err";
          err.textContent = String(e);
          out.appendChild(err);
        }
      });
    });
  });
})();
