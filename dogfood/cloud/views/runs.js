// Runs — launch a named agent on a brief and watch it run live. Opens an EventSource on the
// `agent_run` Live source (GET /live/agent_run), which streams the agent loop's typed events
// (start/text/tools/final/done) and persists a durable Run row (resource Run). The past-runs ledger
// reads GET /cloud/runs. This is the Studio's agent run-visibility surface (Phase 1, wb-fvbs/wb-980e).

WB.view('/runs', { title: 'Runs', accent: 'var(--mint)', fullbleed: true, async render(el){
  var esc = WB.esc;
  var agents = [];
  var runs = [];
  var current = null;   // { status, turns, tokens, lines: [] }
  var es = null;

  function timeAgo(sec){
    if (!sec) return '';
    var d = Math.floor(Date.now() / 1000) - sec;
    if (d < 60) return d + 's'; if (d < 3600) return Math.floor(d/60) + 'm';
    if (d < 86400) return Math.floor(d/3600) + 'h'; return Math.floor(d/86400) + 'd';
  }
  function pill(status){
    var c = status === 'ok' ? 'ok' : (status === 'running' ? 'run' : 'err');
    return '<span class="run-pill ' + c + '">' + esc(status || '—') + '</span>';
  }

  async function load(){
    try {
      var a = await (await fetch('/cloud/agents', { credentials:'same-origin' })).json();
      agents = a.agents || a || [];
    } catch(e){ agents = []; }
    try {
      var r = await (await fetch('/cloud/runs', { credentials:'same-origin' })).json();
      runs = r.runs || [];
    } catch(e){ runs = []; }
  }

  function launch(){
    var sel = el.querySelector('#run-agent');
    var ta  = el.querySelector('#run-task');
    var agent = sel && sel.value, task = ta && ta.value.trim();
    if (!agent || !task) return;
    if (es) { try { es.close(); } catch(e){} }
    current = { agent: agent, task: task, status: 'running', turns: 0, tokens: 0, lines: [] };
    paint();
    var qs = '?agent=' + encodeURIComponent(agent) + '&task=' + encodeURIComponent(task) + '&u=me';
    es = new EventSource('/live/agent_run' + qs);
    es.onmessage = function(m){
      var ev; try { ev = JSON.parse(m.data); } catch(e){ return; }
      onEvent(ev);
    };
    es.onerror = function(){ if (current && current.status === 'running'){ current.status = 'error'; current.lines.push({ k:'error', t:'connection lost' }); paint(); } if (es) es.close(); };
  }

  function onEvent(ev){
    if (!current) return;
    switch (ev.type){
      case 'start': current.lines.push({ k:'start', t:ev.task }); break;
      case 'text':  if (ev.content) current.lines.push({ k:'think', t:ev.content }); break;
      case 'tools': current.lines.push({ k:'tools', t:(ev.commands||[]).join('  ·  ') || (ev.count + ' tool calls') }); break;
      case 'final': current.lines.push({ k:'final', t:ev.answer || '' }); break;
      case 'done':
        current.status = ev.status; current.turns = ev.turns || 0; current.tokens = ev.tokens || 0;
        if (es) es.close();
        load().then(paint); return;
      case 'error': current.status = 'error'; current.lines.push({ k:'error', t:ev.error || 'error' }); break;
      case 'end': return;
    }
    paint();
  }

  function lineHtml(l){
    if (l.k === 'tools')  return '<div class="run-line tools"><span class="run-tag">tools</span><code>' + esc(l.t) + '</code></div>';
    if (l.k === 'think')  return '<div class="run-line think">' + esc(l.t) + '</div>';
    if (l.k === 'final')  return '<div class="run-line final"><span class="run-tag">answer</span><div>' + esc(l.t) + '</div></div>';
    if (l.k === 'error')  return '<div class="run-line error">' + esc(l.t) + '</div>';
    return '<div class="run-line start">▸ ' + esc(l.t) + '</div>';
  }

  function livePanel(){
    if (!current) return '<div class="run-empty">Pick an agent, write a brief, and launch a run to watch it stream.</div>';
    var meter = '<div class="run-meter">' + pill(current.status) +
      '<span class="run-stat">' + current.turns + ' turns</span>' +
      '<span class="run-stat">' + current.tokens + ' tokens</span></div>';
    return '<div class="run-live">' +
      '<div class="run-live-hd"><strong>' + esc(current.agent) + '</strong>' + meter + '</div>' +
      '<div class="run-stream">' + current.lines.map(lineHtml).join('') + '</div></div>';
  }

  function pastRow(r){
    return '<div class="run-row">' +
      '<div class="run-row-top">' + pill(r.status) +
        '<span class="run-row-agent">' + esc(r.agent) + '</span>' +
        '<span class="run-row-meta">' + r.turns + 't · ' + r.tokens + 'tok · ' + esc(timeAgo(r.started)) + '</span></div>' +
      '<div class="run-row-task">' + esc(r.task || '') + '</div>' +
      (r.answer ? '<div class="run-row-ans">' + esc(String(r.answer).slice(0, 240)) + '</div>' : '') +
    '</div>';
  }

  function options(){
    if (!agents.length) return '<option value="">no agents on this nexus</option>';
    return agents.map(function(a){ var n = a.name || a; return '<option value="' + esc(n) + '">' + esc(n) + '</option>'; }).join('');
  }

  function paint(){
    el.innerHTML =
      '<div class="runs-wrap">' +
        '<div class="runs-main">' +
          '<div class="runs-launch">' +
            '<select id="run-agent" class="runs-sel">' + options() + '</select>' +
            '<textarea id="run-task" class="runs-task" rows="2" placeholder="Brief the agent — e.g. \'Draft a 5-slide deck on our Q3 roadmap\'"></textarea>' +
            '<button id="run-go" class="runs-go">Launch run</button>' +
          '</div>' +
          livePanel() +
        '</div>' +
        '<aside class="runs-past"><h2>Recent runs (' + runs.length + ')</h2>' +
          (runs.length ? runs.map(pastRow).join('') : '<div class="run-empty">No runs yet.</div>') +
        '</aside>' +
      '</div>';
    var go = el.querySelector('#run-go'); if (go) go.onclick = launch;
    var ta = el.querySelector('#run-task');
    if (ta) ta.onkeydown = function(e){ if ((e.metaKey||e.ctrlKey) && e.key === 'Enter') launch(); };
  }

  await load();
  paint();
}});

WB.scopedStyles('/runs', `
  .runs-wrap { display:grid; grid-template-columns:1fr 360px; gap:0; height:100%; min-height:0; }
  .runs-main { padding:22px 26px; overflow:auto; }
  .runs-past { border-left:1px solid var(--line); padding:18px; overflow:auto; background:var(--panel,#16181f); }
  .runs-past h2 { font-size:11px; text-transform:uppercase; letter-spacing:.12em; color:var(--dim,#9aa0ad); margin:0 0 12px; }
  .runs-launch { display:grid; grid-template-columns:160px 1fr auto; gap:10px; align-items:start; margin-bottom:18px; }
  .runs-sel, .runs-task { font:inherit; background:#12141b; color:inherit; border:1px solid var(--line); border-radius:9px; padding:9px 11px; }
  .runs-task { resize:vertical; }
  .runs-go { font:inherit; font-weight:650; background:var(--mint,#8ad6c8); color:#04221c; border:0; border-radius:9px; padding:9px 16px; cursor:pointer; }
  .run-empty { color:var(--dim,#9aa0ad); padding:24px 0; }
  .run-live-hd { display:flex; align-items:center; gap:12px; margin-bottom:12px; }
  .run-meter { display:flex; gap:8px; align-items:center; margin-left:auto; }
  .run-stat { font-size:12px; color:var(--dim,#9aa0ad); }
  .run-pill { font-size:11px; font-weight:650; padding:2px 9px; border-radius:999px; text-transform:uppercase; letter-spacing:.06em; }
  .run-pill.ok { background:rgba(158,230,168,.16); color:#9ee6a8; }
  .run-pill.run { background:rgba(138,214,200,.16); color:#8ad6c8; }
  .run-pill.err { background:rgba(244,184,196,.16); color:#f4b8c4; }
  .run-stream { display:flex; flex-direction:column; gap:8px; }
  .run-line { font-size:14px; line-height:1.5; }
  .run-line.start { color:var(--dim,#9aa0ad); }
  .run-line.think { color:var(--dim,#9aa0ad); white-space:pre-wrap; }
  .run-line.tools { display:flex; gap:8px; align-items:center; }
  .run-line.tools code { font-size:12.5px; background:#12141b; border:1px solid var(--line); border-radius:6px; padding:2px 7px; }
  .run-line.final { background:#12141b; border:1px solid var(--line); border-left:3px solid var(--mint,#8ad6c8); border-radius:8px; padding:10px 12px; white-space:pre-wrap; }
  .run-line.error { color:#f4b8c4; }
  .run-tag { font-size:10px; text-transform:uppercase; letter-spacing:.1em; color:var(--dim,#9aa0ad); margin-right:8px; }
  .run-row { border:1px solid var(--line); border-radius:8px; padding:10px 12px; margin-bottom:10px; }
  .run-row-top { display:flex; align-items:center; gap:8px; }
  .run-row-agent { font-weight:600; } .run-row-meta { margin-left:auto; font-size:11.5px; color:var(--dim,#9aa0ad); }
  .run-row-task { font-size:13px; margin-top:4px; } .run-row-ans { font-size:12.5px; color:var(--dim,#9aa0ad); margin-top:4px; }
`);
