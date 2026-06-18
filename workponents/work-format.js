// The work format — a file explorer over the real `sales/` workbook.
// Left: the folder tree (folders = chapters, files = units). Main: the selected
// .work file as literate source, or the salesapp.html build output in a frame.
(function () {
  // ── the real on-disk sales/ tree, in reading order ──
  const TREE = [
    { dir: "",             label: "",           files: ["welcome.work", "index.work"] },
    { dir: "01-foundation", label: "foundation", files: ["types.work", "references.work"] },
    { dir: "02-pages",      label: "pages",      files: ["page.work", "design.work"] },
    { dir: "03-lib",        label: "lib",        files: ["compute.work", "grants.work", "flow.work"] },
    { dir: "04-sandboxing", label: "sandboxing", files: ["sandbox.work"] },
    { dir: "05-data",       label: "data",       files: ["data.work", "query.work"] },
    { dir: "06-dock",       label: "dock",       files: ["contract.work", "dock.work", "nexus.work"] },
    { dir: "kits",          label: "kits",       files: ["kit.work", "use-kit.work"] },
    { dir: "07-agents",     label: "agents",     files: ["brain.work", "coder.work", "researcher.work", "reflexion.work"] },
    { dir: "08-plan",       label: "plan",       files: ["plan.work", "claim.work", "harness.work"] },
    { dir: "09-weave",      label: "weave",      files: ["weave.work", "svelte.work", "solid.work", "rust-zig.work", "python.work"] },
    { dir: "10-deploy",     label: "deploy",     files: ["deploy.work", "delivery.work"] },
    { dir: "90-graph",      label: "graph",      files: ["graph.work"] },
  ];
  const OUTPUT = "salesapp.html";

  // a small mixed mode: markdown prose + Elixir, the way a .work file is written.
  CodeMirror.defineSimpleMode("work", {
    start: [
      { regex: /#{1,6}\s.*/, sol: true, token: "header" },          // markdown heading
      { regex: /\[\[[^\]]+\]\]/, token: "link" },                   // [[backlink]]
      { regex: /#[a-z][\w-]*/, token: "variable-3" },                // #tag
      { regex: /work:\/\/[^\s]+/, token: "link" },                   // work:// deep link
      { regex: /"(?:[^\\"]|\\.)*"/, token: "string" },               // strings
      { regex: /`[^`]*`/, token: "string-2" },                       // inline code
      { regex: /\*\*[^*]+\*\*/, token: "strong" },                   // **bold**
      { regex: /\*[^*\s][^*]*\*/, token: "em" },                     // *italic*
      { regex: /\[[^\]]*\]\([^)]*\)/, token: "link" },               // [text](url)
      { regex: /#.*/, token: "comment" },                            // # comment (non-heading)
      { regex: /:[A-Za-z_]\w*[!?]?/, token: "atom" },                // :atoms
      { regex: /@[A-Za-z_]\w*/, token: "meta" },                     // @module_attrs
      { regex: /\b(?:defmodule|defmacro|defp|def|do|end|cond|case|fn|when|if|else|true|false|nil|import|alias|use|require)\b/, token: "keyword" },
      { regex: /\b(?:client|sandbox|server|rust|zig|python|svelte|solid|flow|agent|resource|record|mutation|enum|variant|seed|data|task|grant|memory|step|parallel|values|query|draft|run|test|of|in|where|order)\b/, token: "variable-2" },
      { regex: /<\/?[A-Za-z][\w-]*/, token: "tag" },                 // html / component tags
      { regex: /\b\d[\d_]*\b/, token: "number" },
      { regex: /./, token: null },
    ],
  });

  const cm = CodeMirror.fromTextArea(document.getElementById("ed"), {
    theme: "material-darker", lineNumbers: true, lineWrapping: false, tabSize: 2, readOnly: true,
  });
  const nav = document.getElementById("nav");
  const fnEl = document.getElementById("fn");
  const lgEl = document.getElementById("lg");
  const frame = document.getElementById("appframe");
  const cmWrap = () => document.querySelector(".CodeMirror");

  // Fill the background of code lines so code reads as a block against prose, and
  // band sandbox blocks with a left rule. Code = inside a do…end, an open bracket
  // continuation (multi-line declarations), or a line that leads with a code word.
  const LEADS = /^\s*(@[A-Za-z]|def\b|defp\b|defmacro\b|defmodule\b|server\b|client\b|sandbox\b|flow\b|agent\b|brain\b|resource\b|record\b|mutation\b|enum\b|variant\b|seed\b|data\b|test\b|query\b|show\b|step\b|import\b|alias\b|use\b|theme\b|rust\b|zig\b|python\b|svelte\b|solid\b|grant\b|parallel\b|with\b|case\b|cond\b|for\b)/;
  function markCode() {
    cm.eachLine(h => ["code-ln", "sb-band", "sb-cap", "sb-end"].forEach(c => cm.removeLineClass(h, "background", c)));
    const n = cm.lineCount();
    let depth = 0, cont = 0;
    for (let i = 0; i < n; i++) {
      const line = cm.getLine(i), trimmed = line.trim();
      const opens = /\bdo\s*$/.test(line), closes = /^\s*end\b/.test(line);
      const inCode = depth > 0 || cont > 0 || opens || closes || LEADS.test(line);
      if (inCode && trimmed !== "") cm.addLineClass(i, "background", "code-ln");
      if (opens) depth++;
      if (closes && depth > 0) depth--;
      if (depth === 0) {
        // count brackets for multi-line code declarations, but ignore markdown
        // ([[backlinks]] and `inline code`) so prose never starts a continuation
        const codeish = line.replace(/\[\[[^\]]*\]?\]?/g, "").replace(/`[^`]*`/g, "");
        const o = (codeish.match(/[([{]/g) || []).length, c = (codeish.match(/[)\]}]/g) || []).length;
        if (cont > 0) cont = Math.max(0, cont + o - c);
        else if (LEADS.test(line)) cont = Math.max(0, o - c);
      }
    }
    // the sandbox containment rail
    const endRe = /^(\s*)end\b/;
    for (let i = 0; i < n; i++) {
      const m = cm.getLine(i).match(/^(\s*)sandbox\b/); if (!m) continue;
      const d = m[1].length; let j = i + 1;
      for (; j < n; j++) { const em = cm.getLine(j).match(endRe); if (em && em[1].length === d) break; }
      if (j >= n) continue;
      cm.addLineClass(i, "background", "sb-cap");
      for (let k = i + 1; k < j; k++) cm.addLineClass(k, "background", "sb-band");
      cm.addLineClass(j, "background", "sb-end");
    }
  }

  function renderTree() {
    let html = `<div class="nav-head"><div class="mk">D</div><h1>Demo</h1>`
             + `<p class="lede">A real workbook, taught as it builds — a tree of <code>.work</code> units. Folders are chapters, files are units. Read it top to bottom.</p></div>`;
    TREE.forEach(group => {
      if (group.label) html += `<div class="sec"><span>${group.label}</span></div>`;
      group.files.forEach(f => {
        const path = group.dir ? group.dir + "/" + f : f;
        html += `<button data-path="${path}"><span class="fic">▤</span><span class="bd"><span class="nm">${f}</span></span></button>`;
      });
    });
    html += `<div class="sec"><span>build output</span></div>`;
    html += `<button data-path="${OUTPUT}" data-out="1"><span class="fic">▶</span><span class="bd"><span class="nm">${OUTPUT}</span><span class="tag">the woven app, rendered</span></span></button>`;
    nav.innerHTML = html;
    nav.querySelectorAll("button").forEach(b => b.onclick = () => loadFile(b.dataset.path, b.dataset.out));
  }

  async function loadFile(path, isOut) {
    nav.querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.path === path));
    const onBtn = nav.querySelector("button.on"); if (onBtn) onBtn.scrollIntoView({ block: "nearest" });
    fnEl.textContent = "sales/" + path;
    if (isOut) {
      cmWrap().style.display = "none";
      frame.style.display = "block";
      frame.src = "sales/" + path;
      lgEl.textContent = "build output";
      return;
    }
    frame.style.display = "none";
    frame.removeAttribute("src");
    cmWrap().style.display = "";
    lgEl.textContent = "work file";
    const txt = await fetch("sales/" + path, { cache: "no-store" }).then(r => r.text());
    cm.setValue(txt);
    setTimeout(() => { cm.refresh(); markCode(); }, 0);
  }

  renderTree();
  loadFile("welcome.work");
})();
