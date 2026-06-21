// Tasks — the orchestration board. Tasks live in resource Task (GET/POST /cloud/tasks); a plan is a
// parent task + subtasks. "Plan with Waldo" (POST /cloud/plan) decomposes a goal into assigned
// subtasks. Dispatch (POST /cloud/task/dispatch) launches the assignee agent as a Run and tracks
// status. Kanban by status. This is the Studio task-management surface (Phase 2, wb-ab25).

WB.view('/tasks', { title: 'Tasks', accent: 'var(--violet)', fullbleed: true, async render(el){
  var esc = WB.esc;
  var tasks = [], agents = [], busy = false;
  var COLS = [
    { id:'open', label:'Open' }, { id:'in_progress', label:'In progress' },
    { id:'blocked', label:'Blocked' }, { id:'done', label:'Done' }
  ];

  async function load(){
    try { tasks = (await (await fetch('/cloud/tasks', {credentials:'same-origin'})).json()).tasks || []; } catch(e){ tasks = []; }
    try { var a = (await (await fetch('/cloud/agents', {credentials:'same-origin'})).json()); agents = (a.agents||a||[]).map(function(x){ return x.name||x; }); } catch(e){ agents = []; }
  }

  async function post(url, body){
    busy = true;
    try { return await (await fetch(url, {method:'POST', credentials:'same-origin', headers:{'content-type':'application/json'}, body:JSON.stringify(body)})).json(); }
    finally { busy = false; }
  }

  function titleOf(tid){ var t = tasks.find(function(x){ return x.tid===tid; }); return t ? t.title : ''; }

  function agentChip(t){
    var opts = ['<option value="">unassigned</option>'].concat(agents.map(function(a){
      return '<option value="'+esc(a)+'"'+(a===t.agent?' selected':'')+'>'+esc(a)+'</option>'; })).join('');
    return '<select class="t-assign" data-tid="'+esc(t.tid)+'">'+opts+'</select>';
  }

  function card(t){
    var canRun = t.agent && (t.status==='open' || t.status==='blocked');
    var parent = t.parent ? '<div class="t-parent">⌞ '+esc(titleOf(t.parent))+'</div>' : '';
    return '<div class="t-card" data-pri="'+(t.priority||2)+'">' +
      parent +
      '<div class="t-title">'+esc(t.title)+'</div>' +
      (t.detail ? '<div class="t-detail">'+esc(String(t.detail).slice(0,140))+'</div>' : '') +
      '<div class="t-foot">' + agentChip(t) +
        (canRun ? '<button class="t-dispatch" data-tid="'+esc(t.tid)+'">▸ Dispatch</button>' : '') +
        (t.run ? '<span class="t-run" data-tip="run '+esc(t.run)+'">↗ run</span>' : '') +
      '</div>' +
      '<div class="t-moves">' + COLS.filter(function(c){return c.id!==t.status;}).map(function(c){
        return '<button class="t-move" data-tid="'+esc(t.tid)+'" data-to="'+c.id+'">'+esc(c.label)+'</button>'; }).join('') +
      '</div></div>';
  }

  function column(c){
    var items = tasks.filter(function(t){ return t.status===c.id; })
                     .sort(function(a,b){ return (a.priority||2)-(b.priority||2); });
    return '<div class="t-col"><div class="t-col-hd">'+esc(c.label)+' <span>'+items.length+'</span></div>' +
      '<div class="t-col-body">'+(items.length?items.map(card).join(''):'<div class="t-empty">—</div>')+'</div></div>';
  }

  function paint(){
    el.innerHTML =
      '<div class="tasks-wrap">' +
        '<div class="tasks-bar">' +
          '<input id="t-new" class="t-input" placeholder="New task title…" />' +
          '<select id="t-new-agent" class="t-input"><option value="">unassigned</option>' +
            agents.map(function(a){ return '<option value="'+esc(a)+'">'+esc(a)+'</option>'; }).join('') + '</select>' +
          '<button id="t-add" class="t-btn">Add task</button>' +
          '<div class="tasks-bar-sp"></div>' +
          '<input id="t-goal" class="t-input t-goal" placeholder="Goal to plan with Waldo…" />' +
          '<button id="t-plan" class="t-btn t-btn-accent">✦ Plan with Waldo</button>' +
        '</div>' +
        '<div class="tasks-board">' + COLS.map(column).join('') + '</div>' +
      '</div>';
    wire();
  }

  function wire(){
    var add = el.querySelector('#t-add');
    if (add) add.onclick = async function(){
      var title = el.querySelector('#t-new').value.trim(); if (!title) return;
      var agent = el.querySelector('#t-new-agent').value;
      await post('/cloud/tasks', { title: title, agent: agent }); await load(); paint();
    };
    var plan = el.querySelector('#t-plan');
    if (plan) plan.onclick = async function(){
      var goal = el.querySelector('#t-goal').value.trim(); if (!goal) return;
      plan.textContent = 'Planning…'; plan.disabled = true;
      await post('/cloud/plan', { goal: goal }); await load(); paint();
    };
    el.querySelectorAll('.t-dispatch').forEach(function(b){ b.onclick = async function(){
      b.textContent = 'running…'; b.disabled = true;
      await post('/cloud/task/dispatch', { tid: b.getAttribute('data-tid') }); await load(); paint();
    };});
    el.querySelectorAll('.t-move').forEach(function(b){ b.onclick = async function(){
      await post('/cloud/task/update', { tid: b.getAttribute('data-tid'), status: b.getAttribute('data-to') }); await load(); paint();
    };});
    el.querySelectorAll('.t-assign').forEach(function(s){ s.onchange = async function(){
      await post('/cloud/task/update', { tid: s.getAttribute('data-tid'), agent: s.value }); await load(); paint();
    };});
  }

  await load();
  paint();
}});

WB.scopedStyles('/tasks', `
  .tasks-wrap { display:flex; flex-direction:column; height:100%; min-height:0; }
  .tasks-bar { display:flex; gap:8px; align-items:center; padding:14px 20px; border-bottom:1px solid var(--line); }
  .tasks-bar-sp { flex:1; }
  .t-input { font:inherit; background:#12141b; color:inherit; border:1px solid var(--line); border-radius:8px; padding:8px 11px; }
  .t-goal { width:280px; }
  .t-btn { font:inherit; background:#222633; color:inherit; border:1px solid var(--line); border-radius:8px; padding:8px 14px; cursor:pointer; }
  .t-btn-accent { background:var(--violet,#b8a6f0); color:#1a1030; border:0; font-weight:650; }
  .tasks-board { flex:1; display:grid; grid-template-columns:repeat(4,1fr); gap:1px; background:var(--line); min-height:0; overflow:hidden; }
  .t-col { background:var(--bg,#0e0f13); display:flex; flex-direction:column; min-height:0; }
  .t-col-hd { padding:11px 14px; font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--dim,#9aa0ad); border-bottom:1px solid var(--line); }
  .t-col-hd span { opacity:.6; }
  .t-col-body { padding:12px; overflow:auto; display:flex; flex-direction:column; gap:10px; }
  .t-empty { color:var(--dim,#9aa0ad); opacity:.4; text-align:center; padding:20px 0; }
  .t-card { background:var(--panel,#16181f); border:1px solid var(--line); border-radius:10px; padding:11px 12px; }
  .t-card[data-pri="0"], .t-card[data-pri="1"] { border-left:3px solid var(--violet,#b8a6f0); }
  .t-parent { font-size:11px; color:var(--dim,#9aa0ad); margin-bottom:3px; }
  .t-title { font-size:13.5px; font-weight:600; line-height:1.35; }
  .t-detail { font-size:12px; color:var(--dim,#9aa0ad); margin-top:4px; }
  .t-foot { display:flex; gap:7px; align-items:center; margin-top:9px; }
  .t-assign { font:inherit; font-size:12px; background:#12141b; color:inherit; border:1px solid var(--line); border-radius:6px; padding:3px 6px; }
  .t-dispatch { font:inherit; font-size:12px; background:var(--mint,#8ad6c8); color:#04221c; border:0; border-radius:6px; padding:4px 9px; cursor:pointer; font-weight:600; }
  .t-run { font-size:11px; color:var(--mint,#8ad6c8); }
  .t-moves { display:flex; gap:5px; margin-top:9px; flex-wrap:wrap; }
  .t-move { font:inherit; font-size:11px; background:transparent; color:var(--dim,#9aa0ad); border:1px solid var(--line); border-radius:6px; padding:2px 8px; cursor:pointer; }
  .t-move:hover { color:var(--ink,#e7e9ee); }
`);
