// Issues — the failure-model triage queue. A failed run auto-files an issue (kind="issue" Task);
// agents/humans file them explicitly. Issues ARE tasks, so triage reuses /cloud/task/update and
// /cloud/task/dispatch: assign an agent + re-dispatch to attempt a fix, or resolve. The list
// separates agent-filed from human-filed (GET /cloud/issues → each issue carries `by`). (wb-35ma)

WB.view('/issues', { title: 'Issues', accent: 'var(--rose,#f4b8c4)', fullbleed: true, async render(el){
  var esc = WB.esc;
  var issues = [], agents = [], filter = 'open';

  async function load(){
    try { issues = (await (await fetch('/cloud/issues', {credentials:'same-origin'})).json()).issues || []; } catch(e){ issues = []; }
    try { var a = await (await fetch('/cloud/agents', {credentials:'same-origin'})).json(); agents = (a.agents||a||[]).map(function(x){ return x.name||x; }); } catch(e){ agents = []; }
  }
  async function post(url, body){ return (await (await fetch(url, {method:'POST', credentials:'same-origin', headers:{'content-type':'application/json'}, body:JSON.stringify(body)})).json()); }

  function timeAgo(sec){ if(!sec) return ''; var d=Math.floor(Date.now()/1000)-sec; if(d<60)return d+'s'; if(d<3600)return Math.floor(d/60)+'m'; if(d<86400)return Math.floor(d/3600)+'h'; return Math.floor(d/86400)+'d'; }

  function assignSel(i){
    var opts = ['<option value="">unassigned</option>'].concat(agents.map(function(a){ return '<option value="'+esc(a)+'"'+(a===i.agent?' selected':'')+'>'+esc(a)+'</option>'; })).join('');
    return '<select class="i-assign" data-tid="'+esc(i.tid)+'">'+opts+'</select>';
  }

  function row(i){
    var byChip = '<span class="i-by '+(i.by==='agent'?'agent':'human')+'">'+(i.by==='agent'?'agent-filed':'human-filed')+'</span>';
    var resolved = i.status === 'done';
    return '<div class="i-card'+(resolved?' done':'')+'">' +
      '<div class="i-top">'+byChip+
        '<span class="i-from">'+esc(i.created_by||'system')+'</span>'+
        (i.run ? '<span class="i-run">↳ run '+esc(String(i.run).slice(0,6))+'</span>' : '')+
        '<span class="i-time">'+esc(timeAgo(i.created))+'</span></div>'+
      '<div class="i-title">'+esc(i.title)+'</div>'+
      (i.detail ? '<pre class="i-detail">'+esc(String(i.detail).slice(0,600))+'</pre>' : '')+
      '<div class="i-foot">'+ assignSel(i) +
        (resolved ? '<span class="i-resolved">✓ resolved</span>' :
          '<button class="i-fix" data-tid="'+esc(i.tid)+'">▸ Re-dispatch fix</button>'+
          '<button class="i-resolve" data-tid="'+esc(i.tid)+'">Resolve</button>')+
      '</div></div>';
  }

  function paint(){
    var shown = issues.filter(function(i){ return filter==='all' || (filter==='open' ? i.status!=='done' : i.status==='done'); });
    var counts = { open: issues.filter(function(i){return i.status!=='done';}).length, done: issues.filter(function(i){return i.status==='done';}).length };
    el.innerHTML =
      '<div class="iss-wrap">'+
        '<div class="iss-bar">'+
          ['open','done','all'].map(function(f){ var lbl = f==='open'?('Open ('+counts.open+')'):f==='done'?('Resolved ('+counts.done+')'):'All';
            return '<button class="iss-tab'+(filter===f?' on':'')+'" data-f="'+f+'">'+lbl+'</button>'; }).join('')+
        '</div>'+
        '<div class="iss-list">'+(shown.length?shown.map(row).join(''):'<div class="iss-empty">No issues here. A failed run files one automatically.</div>')+'</div>'+
      '</div>';
    el.querySelectorAll('.iss-tab').forEach(function(b){ b.onclick=function(){ filter=b.getAttribute('data-f'); paint(); }; });
    el.querySelectorAll('.i-assign').forEach(function(s){ s.onchange=async function(){ await post('/cloud/task/update',{tid:s.getAttribute('data-tid'),agent:s.value}); await load(); paint(); }; });
    el.querySelectorAll('.i-resolve').forEach(function(b){ b.onclick=async function(){ await post('/cloud/task/update',{tid:b.getAttribute('data-tid'),status:'done'}); await load(); paint(); }; });
    el.querySelectorAll('.i-fix').forEach(function(b){ b.onclick=async function(){ b.textContent='running…'; b.disabled=true; await post('/cloud/task/dispatch',{tid:b.getAttribute('data-tid')}); await load(); paint(); }; });
  }

  await load();
  paint();
}});

WB.scopedStyles('/issues', `
  .iss-wrap { display:flex; flex-direction:column; height:100%; min-height:0; }
  .iss-bar { display:flex; gap:6px; padding:14px 20px; border-bottom:1px solid var(--line); }
  .iss-tab { font:inherit; font-size:13px; background:transparent; color:var(--dim,#9aa0ad); border:1px solid var(--line); border-radius:8px; padding:6px 13px; cursor:pointer; }
  .iss-tab.on { background:var(--rose,#f4b8c4); color:#3a0f1a; border-color:transparent; font-weight:650; }
  .iss-list { flex:1; overflow:auto; padding:18px 20px; display:flex; flex-direction:column; gap:12px; max-width:880px; }
  .iss-empty { color:var(--dim,#9aa0ad); padding:30px 0; }
  .i-card { background:var(--card); border:1px solid var(--line); border-left:3px solid var(--rose,#f4b8c4); border-radius:10px; padding:13px 15px; color:var(--ink); }
  .i-card.done { border-left-color:var(--ok,#9ee6a8); opacity:.7; }
  .i-top { display:flex; align-items:center; gap:9px; font-size:12px; color:var(--dim,#9aa0ad); }
  .i-by { font-size:10px; text-transform:uppercase; letter-spacing:.07em; padding:2px 7px; border-radius:999px; font-weight:650; }
  .i-by.agent { background:rgba(138,214,200,.16); color:var(--mint,#8ad6c8); }
  .i-by.human { background:rgba(184,166,240,.16); color:var(--violet,#b8a6f0); }
  .i-run { color:var(--mint,#8ad6c8); } .i-time { margin-left:auto; }
  .i-title { font-size:14.5px; font-weight:600; margin-top:7px; }
  .i-detail { font-size:12px; color:var(--dim,#9aa0ad); white-space:pre-wrap; background:var(--bg); border:1px solid var(--line); border-radius:7px; padding:9px 11px; margin:8px 0 0; max-height:160px; overflow:auto; font-family:ui-monospace,monospace; }
  .i-title { color:var(--ink); }
  .i-foot { display:flex; align-items:center; gap:8px; margin-top:11px; }
  .i-assign { font:inherit; font-size:12px; background:var(--bg); color:inherit; border:1px solid var(--line); border-radius:6px; padding:4px 7px; }
  .i-fix { font:inherit; font-size:12px; background:var(--mint,#8ad6c8); color:#04221c; border:0; border-radius:6px; padding:5px 11px; cursor:pointer; font-weight:600; }
  .i-resolve { font:inherit; font-size:12px; background:transparent; color:var(--dim,#9aa0ad); border:1px solid var(--line); border-radius:6px; padding:5px 11px; cursor:pointer; }
  .i-resolved { font-size:12px; color:var(--ok,#9ee6a8); } .i-from { font-weight:500; }
`);
