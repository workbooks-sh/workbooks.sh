  const RUN_SCORE = [
    `<span class="p">$</span> <span class="cmd">work run score</span>`,
    ``,
    `  <span class="dim">compile</span>  score   <span class="dim">elixir → wasm (sandbox)</span>   <span class="num">88ms</span>`,
    `  <span class="dim">load</span>     score.wasm   <span class="dim">wasmtime · 1 instance</span>`,
    `  <span class="dim">call</span>     score(%{revenue: 50_000, employees: 20})`,
    `  <span class="ok">=></span>       <span class="num">70</span>`,
    ``,
    `  <span class="ok">✓</span> ran in <span class="num">96ms</span> · in the sandbox`,
  ];
  const RUN_FLOW = [
    `<span class="p">$</span> <span class="cmd">work run pipeline</span>`,
    ``,
    `  <span class="dim">flow</span> pipeline`,
    `  <span class="ok">→</span> seed      <span class="dim">12 leads</span>   <span class="num">4ms</span>`,
    `  <span class="ok">→</span> enrich    <span class="dim">12 leads</span>   <span class="num">88ms</span>`,
    `  <span class="warn">∥</span> min | max <span class="dim">parallel</span>   <span class="num">3ms</span>`,
    `  <span class="ok">→</span> score     <span class="dim">12 leads</span>   <span class="num">12ms</span>`,
    `  <span class="ok">=></span> ranked <span class="dim">(12 rows)</span>`,
    ``,
    `  <span class="ok">✓</span> flow done in <span class="num">107ms</span>`,
  ];
  const RUN_UNIT = [
    `<span class="p">$</span> <span class="cmd">work run score</span>`,
    ``,
    `  <span class="dim">compile</span>  score   <span class="dim">elixir → wasm (sandbox)</span>   <span class="num">88ms</span>`,
    `  <span class="dim">call</span>     score(%{revenue: 50_000, employees: 20})`,
    `  <span class="ok">=></span>       <span class="num">70</span>`,
    ``,
    `  <span class="ok">✓</span> a unit is just a name — resolved + ran`,
  ];
  const RUN_ENRICH = [
    `<span class="p">$</span> <span class="cmd">work run enrich</span>`,
    ``,
    `  <span class="dim">compile</span>  enrich   <span class="dim">rust → wasm (clang, in-sandbox)</span>   <span class="num">412ms</span>`,
    `  <span class="dim">load</span>     enrich.wasm   <span class="dim">wasmtime</span>`,
    `  <span class="dim">call</span>     enrich(1000)`,
    `  <span class="ok">=></span>       <span class="num">1100</span>`,
    `  <span class="dim">test</span>     enrich 2/2 <span class="ok">✓</span>`,
    ``,
    `  <span class="ok">✓</span> ran in <span class="num">0.5s</span>`,
  ];
  const RUN_TYPES = [
    `<span class="p">$</span> <span class="cmd">work check team.work</span>`,
    ``,
    `  <span class="dim">type</span>     Status = :todo | :doing | :done   <span class="ok">✓</span>`,
    `  <span class="dim">users</span>    :analyst <span class="ok">✓</span>   :shane <span class="ok">✓</span>`,
    `  <span class="dim">refs</span>     task owner: :analyst   <span class="ok">✓ resolves</span>`,
    `           task status: :todo     <span class="ok">✓ valid Status</span>`,
    ``,
    `  <span class="warn">✗</span> would fail:  owner: :nobody   <span class="dim">(no such user)</span>`,
    ``,
    `  <span class="ok">✓</span> 3 tasks · 2 users · 1 type — typed, no drift`,
  ];

  const RUN_PLAN = [
    `<span class="p">$</span> <span class="cmd">work plan run</span>`,
    ``,
    `  <span class="dim">plan.work</span>   2 agents · 4 tasks`,
    ``,
    `  <span class="ok">→</span> ada  claims <span class="cmd">"enrich the leads"</span>   <span class="dim">draft</span> <span class="path">wb-7f3</span> · <span class="dim">scope</span> <span class="path">[enrich.work]</span>`,
    `  <span class="ok">→</span> rex  claims <span class="cmd">"score + rank"</span>       <span class="dim">draft</span> <span class="path">wb-7f4</span> · <span class="dim">scope</span> <span class="path">[score.work]</span>`,
    `  <span class="warn">∥</span> both running — <span class="dim">isolated changes, no collision</span>`,
    ``,
    `  <span class="ok">✓</span> ada  enrich.work  <span class="dim">status</span> <span class="ok">:done</span>  merged`,
    `  <span class="ok">→</span> rex  was blocked on <span class="dim">:score</span> → now ready`,
    `  <span class="dim">□</span> "email the analyst"  <span class="warn">unassigned</span> <span class="dim">— open slot</span>`,
    ``,
    `  <span class="ok">✓</span> plan advanced · <span class="num">2</span> done · <span class="num">1</span> doing · <span class="num">1</span> open`,
  ];

  const RUN_HARNESS = [
    `<span class="p">$</span> <span class="cmd">work plan run</span>`,
    ``,
    `  <span class="dim">plan.work</span>   1 agent · 1 flow · 3 tasks · 1 validation`,
    ``,
    `  <span class="ok">→</span> ada  claims <span class="cmd">"run the pipeline"</span>   <span class="dim">draft</span> <span class="path">wb-9a1</span> · <span class="dim">scope</span> <span class="path">[leads/]</span>`,
    `  <span class="dim">flow</span> pipeline`,
    `  <span class="ok">→</span> enrich   <span class="dim">rust → wasm</span>   <span class="num">412ms</span>`,
    `  <span class="dim">test</span> enrich 1/1 <span class="ok">✓</span>   <span class="dim">validation gate passed</span>`,
    `  <span class="ok">→</span> score    <span class="dim">12 leads</span>   <span class="num">12ms</span>`,
    `  <span class="warn">∥</span> rank | chart <span class="dim">parallel</span>   <span class="num">3ms</span>`,
    `  <span class="ok">=></span> ranked <span class="dim">(12 rows)</span>`,
    ``,
    `  <span class="ok">✓</span> "run the pipeline" <span class="ok">:done</span> → unblocks "review the ranking"`,
    `  <span class="ok">✓</span> harness complete · brain + flow + tasks + validation, one file`,
  ];

  const RUN_CODER = [
    `<span class="p">$</span> <span class="cmd">work run coder "fix the failing test"</span>`,
    ``,
    `  <span class="dim">agent</span> coder · mimo · tools [bash edit read search]`,
    `  <span class="ok">→</span> read   <span class="path">test/scorer_test.exs</span>`,
    `  <span class="ok">→</span> bash   <span class="cmd">mix test</span>   <span class="dim">sandbox · ./project</span>   <span class="warn">1 failed</span>`,
    `  <span class="ok">→</span> edit   <span class="path">lib/scorer.ex</span>   <span class="dim">off-by-one</span>`,
    `  <span class="ok">→</span> bash   <span class="cmd">mix test</span>   <span class="dim">sandbox</span>   <span class="ok">12 passed</span>`,
    ``,
    `  <span class="ok">=></span> done · <span class="num">4</span> steps · all tests green`,
  ];
  const RUN_RESEARCH = [
    `<span class="p">$</span> <span class="cmd">work run researcher "what powers WASI preview 3?"</span>`,
    ``,
    `  <span class="dim">flow</span> research`,
    `  <span class="ok">→</span> plan      <span class="dim">5 sub-queries</span>`,
    `  <span class="warn">∥</span> search    <span class="dim">5 parallel · web_search</span>   <span class="num">1.2s</span>`,
    `  <span class="ok">→</span> verify    <span class="dim">18 findings → 11 confident</span>`,
    `  <span class="ok">→</span> synthesize`,
    `  <span class="warn">↻</span> critique  <span class="dim">2 gaps → another round</span>`,
    ``,
    `  <span class="ok">=></span> report · <span class="num">11</span> sourced findings`,
  ];

  // ONE ordered lesson plan — read top to bottom, the way you'd teach it.
  const SECTIONS = [
    { title:"The idea", blurb:"the mental model, before any syntax",
      lessons:[
        { nm:"The four lanes", tag:"every line, decided by who reads it", fn:"the model", lg:"—",      mode:"work", code:"c-prim-lanes", exp:"e-prim-lanes" },
        { nm:"The unit",       tag:"the one addressable thing",           fn:"the model", lg:"elixir", mode:"work", code:"c-prim-unit",  exp:"e-prim-unit", run:RUN_UNIT },
        { nm:"The block",      tag:"do…end — one delimiter",              fn:"the model", lg:"elixir", mode:"work", code:"c-prim-block", exp:"e-prim-block" },
        { nm:"References",     tag:"names are the only glue",             fn:"the model", lg:"—",      mode:"work", code:"c-prim-refs",  exp:"e-prim-refs" },
        { nm:"Tags & links",   tag:"address by name/tag, not path",       fn:"the model", lg:"—",      mode:"work", code:"c-ref-tags",   exp:"e-ref-tags" },
        { nm:"The map",        tag:"every primitive → its lane",          fn:"the model", lg:"—",      mode:"work", code:"c-prim-map",   exp:"e-prim-map" },
      ] },
    { title:"Rich text", blurb:"markdown — the only thing a human reads",
      lessons:[
        { nm:"Prose",    tag:"what you read",          fn:"page.work", lg:"markdown", mode:"work", code:"c-syn-prose", exp:"e-syn-prose" },
        { nm:"Headings", tag:"the narrative outline",  fn:"page.work", lg:"markdown", mode:"work", code:"c-syn-head",  exp:"e-syn-head" },
        { nm:"Figures",  tag:"richer than markdown",   fn:"page.work", lg:"markdown", mode:"work", code:"c-syn-fig",   exp:"e-syn-fig" },
      ] },
    { title:"Code", blurb:"Elixir — everything that runs",
      lessons:[
        { nm:"Targets",       tag:"client · sandbox · server",       fn:"page.work", lg:"target",        mode:"work", code:"c-syn-fence",   exp:"e-syn-fence" },
        { nm:"Compute",       tag:"a sandbox def → wasm",          fn:"page.work", lg:"elixir",        mode:"work", code:"c-syn-compute", exp:"e-syn-compute", run:RUN_SCORE },
        { nm:"Workflows",     tag:"if it runs, it's Elixir",       fn:"page.work", lg:"elixir",        mode:"work", code:"c-syn-flow",    exp:"e-syn-flow", run:RUN_FLOW },
        { nm:"Tests",         tag:"red test, no bundle",           fn:"page.work", lg:"elixir",        mode:"work", code:"c-syn-test",    exp:"e-syn-test" },
      ] },
    { title:"Data", blurb:"one typed surface — WIT types, no SQL-as-format",
      lessons:[
        { nm:"Tasks",      tag:"the contested line — text or data",   fn:"page.work", lg:"md · elixir", mode:"work", code:"c-syn-tasks", exp:"e-syn-tasks" },
        { nm:"Types",      tag:"defined once, referenced everywhere", fn:"team.work", lg:"elixir",      mode:"work", code:"c-prim-types",exp:"e-prim-types", run:RUN_TYPES },
        { nm:"The data model", tag:"one typed surface — WIT",          fn:"team.work", lg:"elixir",      mode:"work", code:"c-data-model",exp:"e-data-model" },
        { nm:"The header", tag:"the file's Elixir header — no YAML",   fn:"page.work", lg:"elixir",      mode:"work", code:"c-syn-front", exp:"e-syn-front" },
      ] },
    { title:"The app model", blurb:"index + files → the weave → one HTML",
      lessons:[
        { nm:"index.work",      tag:"manifest · deps · nexus · checks", fn:"index.work",      lg:"elixir",      mode:"work", code:"c-model-index",  exp:"e-model-index" },
        { nm:"Packages",        tag:"deps: one manifest, no mix/vite",  fn:"index.work",      lg:"elixir",      mode:"work", code:"c-model-pkg",    exp:"e-model-pkg" },
        { nm:"A page",          tag:"rich text + tasks + an island",    fn:"dashboard.work",  lg:"md · svelte", mode:"work",      code:"c-model-dash",   exp:"e-model-dash" },
        { nm:"A compute unit",  tag:"a sandbox unit → wasm",            fn:"enrich.work",     lg:"md · rust",   mode:"work",      code:"c-model-enrich", exp:"e-model-enrich", run:RUN_ENRICH },
        { nm:"The weave",       tag:"the CLI: dev loop + ship",         fn:"work bundle",     lg:"cli",         term:true,                               exp:"e-model-weave" },
        { nm:"dist/index.html", tag:"one HTML + a gzip blob inside",    fn:"dist/index.html", lg:"deliverable", mode:"htmlmixed", code:"c-model-dist",   exp:"e-model-dist" },
      ] },
    { title:"Toolkits", blurb:"external deps, shipped as helpers",
      lessons:[
        { nm:"Use a toolkit", tag:"import a package of helpers",     fn:"index.work", lg:"elixir", mode:"work", code:"c-tk-use",    exp:"e-tk-use" },
        { nm:"Author one",    tag:"a work file that exports a prefix", fn:"crm.work",   lg:"elixir", mode:"work", code:"c-tk-author", exp:"e-tk-author" },
      ] },
    { title:"The Dock & runtime", blurb:"one capability seam; the optional server tier",
      lessons:[
        { nm:"The one seam",   tag:"request → membrane → provider",   fn:"the dock",   lg:"—",      mode:"work", code:"c-dock-seam", exp:"e-dock-seam" },
        { nm:"Providers",      tag:"local vs runtime, same request",  fn:"the dock",   lg:"—",      mode:"work", code:"c-dock-prov", exp:"e-dock-prov" },
        { nm:"The contract",   tag:"a WIT world: exports + imports",  fn:"the dock",   lg:"wit",    mode:"work", code:"c-rt-wit",   exp:"e-rt-wit" },
        { nm:"What the nexus backs", tag:"the optional server tier",  fn:"index.work", lg:"—",      mode:"work", code:"c-nx-backs",  exp:"e-nx-backs" },
        { nm:"Extrapolate",    tag:"server work: build OR nexus",     fn:"page.work",  lg:"elixir", mode:"work", code:"c-nx-extrap", exp:"e-nx-extrap" },
        { nm:"Data sources",   tag:"values · blob · resource",        fn:"page.work",  lg:"elixir", mode:"work", code:"c-dt-src",    exp:"e-dt-src" },
        { nm:"Query & show",   tag:"select, then render itself",      fn:"page.work",  lg:"elixir", mode:"work", code:"c-dt-query",  exp:"e-dt-query" },
      ] },
    { title:"Security", blurb:"what publishing exposes",
      lessons:[
        { nm:"Postures",       tag:"public / gated_data / gated_route", fn:"index.work", lg:"elixir", mode:"work", code:"c-sec-post", exp:"e-sec-post" },
        { nm:"Caps & secrets", tag:"requests, not authority",           fn:"index.work", lg:"elixir", mode:"work", code:"c-sec-caps", exp:"e-sec-caps" },
      ] },
    { title:"Agents", blurb:"a brain — and whole agent frameworks in one file",
      lessons:[
        { nm:"The brain",       tag:"system + model + tools, runtime-backed", fn:"analyst.work",  lg:"elixir", mode:"work", code:"c-ag-brain",       exp:"e-ag-brain" },
        { nm:"Coding agent",    tag:"ReAct + sandboxed tools (Claude-Code)",  fn:"coder.work",    lg:"elixir", mode:"work", code:"c-agent-coder",     exp:"e-agent-coder", run:RUN_CODER },
        { nm:"Auto-researcher", tag:"plan → search → verify → synth (loop)",  fn:"researcher.work",lg:"elixir", mode:"work", code:"c-agent-research", exp:"e-agent-research", run:RUN_RESEARCH },
        { nm:"Reflexion",       tag:"generate → critique → revise; memory=trace",fn:"reflexion.work",lg:"elixir", mode:"work", code:"c-agent-reflexion",exp:"e-agent-reflexion" },
      ] },
    { title:"Plans & live state", blurb:"tasks as live, multi-agent state — the document is the store",
      lessons:[
        { nm:"Live state",         tag:"declarative ≠ immutable",        fn:"plan.work", lg:"elixir", mode:"work", code:"c-live-state", exp:"e-live-state" },
        { nm:"plan.work",          tag:"plan + board + audit, one file", fn:"plan.work", lg:"elixir", mode:"work", code:"c-live-plan",  exp:"e-live-plan", run:RUN_PLAN },
        { nm:"Claim, lock & fence",tag:"drafts isolate · scopes fence",  fn:"plan.work", lg:"elixir", mode:"work", code:"c-live-claim", exp:"e-live-claim" },
        { nm:"A full harness",     tag:"agent + flow + tasks + tests",   fn:"plan.work", lg:"elixir", mode:"work", code:"c-plan-harness", exp:"e-plan-harness", run:RUN_HARNESS },
      ] },
    { title:"Deploy", blurb:"two targets, one image",
      lessons:[
        { nm:"Two targets", tag:"local + cloud, one image", fn:"work deploy", lg:"cli", mode:"work", code:"c-dep", exp:"e-dep" },
      ] },
  ];
  const LESSONS = SECTIONS.flatMap(s => s.lessons);   // flat index for prev/next + nav

  const WEAVE = [
    `<span class="p">$</span> <span class="cmd">work dev</span>`,
    `  <span class="ok">◐</span> dev server  <span class="path">http://localhost:5180</span>   ready in 240ms · <span class="dim">HMR on</span>`,
    `  <span class="dim">~</span> dashboard.work · board.svelte → <span class="ok">hot-replaced</span> 18ms`,
    ``,
    `<span class="p">$</span> <span class="cmd">work bundle sales/</span>`,
    ``,
    `  <span class="dim">workbook</span>  sales/  ·  1 index · 2 work files`,
    ``,
    `  <span class="dim">resolve</span>   index → dashboard.work <span class="ok">✓</span>  enrich.work <span class="ok">✓</span>`,
    `            packages   d3@7 <span class="ok">✓</span>  regex@1.10 <span class="ok">✓</span>`,
    `            toolkits   crm@2 <span class="ok">✓</span>  charts@1 <span class="ok">✓</span>`,
    ``,
    `  <span class="dim">caps</span>      net api.crm.com <span class="ok">✓</span>   env CRM_API_KEY <span class="ok">✓</span> <span class="dim">(host-bound)</span>`,
    `            audit declared-only <span class="ok">✓</span>  <span class="dim">no over-reach</span>`,
    ``,
    `  <span class="dim">compile</span>   rust    enrich.rs   → <span class="path">enrich.wasm</span>   <span class="num">412ms</span>`,
    `            elixir  score(orb)  → <span class="path">score.wasm</span>    <span class="num">88ms</span>`,
    `            svelte  board       → <span class="path">board.js</span> 12KB <span class="num">340ms</span>`,
    ``,
    `  <span class="dim">check</span>     ts strict <span class="ok">✓</span>      tests  enrich 2/2 <span class="ok">✓</span>`,
    `  <span class="dim">weave</span>     ssr (beam) <span class="ok">✓</span>     islands 1 <span class="ok">✓</span>`,
    `  <span class="dim">bundle</span>    <span class="path">dist/index.html</span>  <span class="num">34 KB gz</span>  posture <span class="warn">gated_data</span>`,
    ``,
    `  <span class="ok">✓</span> assembled in <span class="num">1.1s</span>  ·  secrets + gated rows stayed out`,
  ];

  // a small mixed mode: markdown prose + Elixir, the way a .work file is written.
  CodeMirror.defineSimpleMode("work", {
    start: [
      { regex: /#{1,6}\s.*/, sol: true, token: "header" },         // markdown heading
      { regex: /"(?:[^\\"]|\\.)*"/, token: "string" },              // strings
      { regex: /`[^`]*`/, token: "string-2" },                      // inline code
      { regex: /\?(?:\\.|[^\s])/, token: "string-2" },              // char literals  ?,  ?\n
      { regex: /\*\*[^*]+\*\*/, token: "strong" },                  // **bold**
      { regex: /\*[^*\s][^*]*\*/, token: "em" },                    // *italic*
      { regex: /\[[^\]]*\]\([^)]*\)/, token: "link" },              // [text](url)
      { regex: /#.*/, token: "comment" },                           // # comment (non-heading)
      { regex: /:[A-Za-z_]\w*[!?]?/, token: "atom" },               // :atoms
      { regex: /@[A-Za-z_]\w*/, token: "meta" },                    // @module_attrs
      { regex: /\b(?:defmodule|defmacro|defp|def|do|end|cond|case|fn|when|if|else|true|false|nil|import|alias|use|require)\b/, token: "keyword" },
      { regex: /\b(?:client|sandbox|server|world|export|import|interface|package|component|func|record|variant|enum|flags|values|select|blob|postgres|data|tagged|tags|use|import|tangle|untangle|flow|figure|note|task|user|type|step|parallel|todo|doing|done|agent|validate|grant|memory)\b/, token: "variable-2" },
      { regex: /<\/?[A-Za-z][\w-]*/, token: "tag" },                // <work-* / html tags
      { regex: /\b\d[\d_]*\b/, token: "number" },
      { regex: /./, token: null },
    ],
  });

  const grab = (id) => document.getElementById(id).textContent
        .replace(/^\n/,"").replace(/\s+$/,"").replace(/<\\\/script>/g,"<\/script>");
  const cm = CodeMirror.fromTextArea(document.getElementById("ed"), {
    theme:"material-darker", lineNumbers:true, lineWrapping:false, tabSize:2, readOnly:false,
  });
  const nav  = document.getElementById("nav");
  const exp  = document.getElementById("exp");
  const term = document.getElementById("term");
  const fnEl = document.getElementById("fn");
  const lgEl = document.getElementById("lg");
  const drawer=document.getElementById("drawer"), dterm=document.getElementById("dterm"),
        dclose=document.getElementById("dclose"), dtitle=document.getElementById("dtitle"),
        runbtn=document.getElementById("runbtn");
  let termTimer=null, drawerTimer=null, cur=0;

  function streamDrawer(lines){
    dterm.innerHTML=""; if(drawerTimer)clearTimeout(drawerTimer);
    let k=0;
    (function step(){
      if(k<lines.length){ const d=document.createElement("div"); d.className="tl"; d.innerHTML=lines[k++]||"&nbsp;"; dterm.appendChild(d); dterm.scrollTop=dterm.scrollHeight; drawerTimer=setTimeout(step,55); }
      else { const c=document.createElement("span"); c.className="cur"; c.textContent="▋"; dterm.appendChild(c); }
    })();
  }
  function closeDrawer(){ if(drawerTimer){clearTimeout(drawerTimer);drawerTimer=null;} drawer.classList.remove("open"); setTimeout(()=>cm.refresh(),210); }
  runbtn.onclick=()=>{
    const t=LESSONS[cur];
    if(!t.run) return;
    if(drawer.classList.contains("open")){ closeDrawer(); return; }
    dtitle.textContent="run · "+t.fn;
    drawer.classList.add("open");
    streamDrawer(t.run);
    setTimeout(()=>cm.refresh(),210);
  };
  dclose.onclick=closeDrawer;

  function runTerm(){
    term.innerHTML=""; if(termTimer)clearTimeout(termTimer);
    let k=0;
    (function step(){
      if(k<WEAVE.length){
        const d=document.createElement("div"); d.className="tl"; d.innerHTML=WEAVE[k++]||"&nbsp;";
        term.appendChild(d); term.scrollTop=term.scrollHeight;
        termTimer=setTimeout(step,42);
      } else { const c=document.createElement("span"); c.className="cur"; c.textContent="▋"; term.appendChild(c); }
    })();
  }

  function loadLesson(i){
    cur = i;
    const t = LESSONS[i];
    const isTerm = !!t.term;
    runbtn.classList.toggle("show", !!t.run);
    closeDrawer();
    const cmWrap = document.querySelector(".CodeMirror");
    if(cmWrap) cmWrap.style.display = isTerm ? "none" : "";
    term.style.display = isTerm ? "block" : "none";
    if(termTimer){ clearTimeout(termTimer); termTimer=null; }
    if(isTerm){ runTerm(); }
    else { cm.setOption("mode", t.mode||"null"); cm.setValue(grab(t.code)); setTimeout(()=>cm.refresh(),0); }
    fnEl.textContent = t.fn; lgEl.textContent = t.lg;
    exp.innerHTML=""; exp.appendChild(document.getElementById(t.exp).content.cloneNode(true)); exp.scrollTop=0;
    nav.querySelectorAll("button").forEach((b,j)=>b.classList.toggle("on", j===i));
    const onBtn = nav.querySelector("button.on"); if(onBtn) onBtn.scrollIntoView({block:"nearest"});
  }

  function renderNav(){
    let html = `<div class="nav-head"><div class="mk">W</div><h1>The work format</h1>`
             + `<p class="lede">One lesson plan, top to bottom. Markdown narrates; Elixir runs &amp; declares. Read it like a short course.</p></div>`;
    let gi = 0;
    SECTIONS.forEach((s,si)=>{
      html += `<div class="sec"><span class="sn">${String(si+1).padStart(2,"0")}</span><span>${s.title}</span><i>${s.blurb}</i></div>`;
      s.lessons.forEach(t=>{
        const n = String(gi+1).padStart(2,"0");
        html += `<button data-i="${gi}"><span class="ln">${n}</span><span class="bd"><span class="nm">${t.nm}</span><span class="tag">${t.tag}</span></span></button>`;
        gi++;
      });
    });
    nav.innerHTML = html;
    nav.querySelectorAll("button").forEach(b=>b.onclick=()=>loadLesson(+b.dataset.i));
  }

  (function(){
    const drag=document.getElementById("drag"), expEl=document.querySelector(".exp");
    let on=false;
    drag.addEventListener("pointerdown",e=>{on=true;drag.classList.add("on");drag.setPointerCapture(e.pointerId);document.body.style.userSelect="none";});
    drag.addEventListener("pointermove",e=>{if(!on)return;const w=window.innerWidth-e.clientX;expEl.style.width=Math.max(240,Math.min(760,w))+"px";});
    const end=()=>{if(!on)return;on=false;drag.classList.remove("on");document.body.style.userSelect="";cm.refresh();};
    drag.addEventListener("pointerup",end);drag.addEventListener("pointercancel",end);
  })();

