// Inbox — the email-style unified feed (list + detail pane). The LEFT shell sidebar is the filter
// funnel (saved views + search, painted by paintInboxFunnel in app.js); THIS page is the mailbox:
// a scannable list of semantic THREADS and a detail pane for the selected one. The server
// (/cloud/inbox) classifies every thread into {semantic, severity, blame, friendly title + snippet}
// so nothing raw (run ids, FunctionClauseError, task prompts) ever leaks to the top — progressive
// disclosure: row → pane → "technical details". Mailbox behaviors: unread/read, archive, needs-you.

WB.view('/activity', { title: 'Inbox', accent: 'var(--violet)', fullbleed: true, async render(el){
  var esc = WB.esc;
  var threads = [], sel = null;

  function timeAgo(sec){
    if (!sec) return '';
    var d = Math.floor(Date.now()/1000) - sec;
    if (d < 60) return d + 's'; if (d < 3600) return Math.floor(d/60) + 'm';
    if (d < 86400) return Math.floor(d/3600) + 'h'; return Math.floor(d/86400) + 'd';
  }
  async function post(url, body){ return (await (await fetch(url, {method:'POST', credentials:'same-origin', headers:{'content-type':'application/json'}, body:JSON.stringify(body)})).json()); }

  // Parse a saved-view filter spec ("status=needs_you;semantic=run_done,chat") into a predicate.
  function specPred(spec){
    var clauses = String(spec || '').split(';').filter(Boolean).map(function(c){
      var kv = c.split('='); return { k: kv[0], vals: (kv[1]||'').split(',').filter(Boolean) };
    });
    return function(t){
      return clauses.every(function(cl){
        if (cl.k === 'status') return cl.vals.some(function(v){
          return v === 'needs_you' ? t.needs_you : v === 'unread' ? !t.read : v === 'archived' ? t.archived
            : v === 'open' ? (t.tech && t.tech.status && t.tech.status !== 'done') : v === 'resolved' ? t.semantic === 'resolved' : true;
        });
        if (cl.k === 'semantic') return cl.vals.indexOf(t.semantic) >= 0;
        if (cl.k === 'actor') return cl.vals.indexOf(t.actor) >= 0;
        return true;
      });
    };
  }

  function activeFilter(){ return (WB._inboxFilter || { filters: '', q: '' }); }
  function visible(){
    var f = activeFilter(); var pred = specPred(f.filters); var q = (f.q || '').toLowerCase().trim();
    return threads.filter(function(t){
      if (!pred(t)) return false;
      if (q){ var hay = (t.title + ' ' + t.snippet + ' ' + t.actor).toLowerCase(); if (hay.indexOf(q) < 0) return false; }
      return true;
    });
  }

  // Fill the funnel's per-view counts (the page owns the data, the funnel owns the chrome).
  WB._inboxCounts = function(){
    (WB._inboxViews || []).forEach(function(v){
      var n = threads.filter(specPred(v.filters)).length;
      document.querySelectorAll('[data-ibxcount="' + (window.CSS && CSS.escape ? CSS.escape(v.name) : v.name) + '"]').forEach(function(s){ s.textContent = n ? n : ''; });
    });
    var nu = threads.filter(function(t){ return t.needs_you; }).length;
    document.querySelectorAll('[data-ibxcount="Needs you"]').forEach(function(s){ s.textContent = nu ? nu : ''; });
    document.querySelectorAll('[data-ibxcount="Inbox"]').forEach(function(s){ var n = threads.filter(function(t){return !t.archived;}).length; s.textContent = n ? n : ''; });
    // The rail badge = needs-you count only.
    var badge = document.querySelector('[data-nav="/activity"] .railbadge');
    var rail = document.querySelector('[data-nav="/activity"]');
    if (rail){ if (!badge && nu){ badge = document.createElement('span'); badge.className = 'railbadge'; rail.appendChild(badge); }
      if (badge){ badge.textContent = nu || ''; badge.style.display = nu ? '' : 'none'; } }
  };

  function dot(sev){ return '<span class="ibdot ' + (sev || 'low') + '"></span>'; }

  function listRow(t){
    return '<button class="ibl' + (t.needs_you ? ' need' : '') + (t.read ? '' : ' unread') + (sel && sel.subject === t.subject ? ' on' : '') + '" data-sub="' + esc(t.subject) + '">' +
      dot(t.severity) +
      '<span class="iblbody">' +
        '<span class="iblrow1"><span class="iblt">' + esc(t.title) + '</span><span class="iblw">' + esc(timeAgo(t.at)) + '</span></span>' +
        '<span class="ibls">' + esc(t.snippet || '') + '</span>' +
        '<span class="iblmeta">' + esc(t.actor || 'system') + (t.needs_you ? ' · <span class="iblneed">needs you</span>' : '') + '</span>' +
      '</span></button>';
  }

  function paneFor(t){
    if (!t) return '<div class="ibpane-empty"><div class="ibpe-ic">' + ENVELOPE + '</div>' +
      '<div class="ibpe-t">All caught up</div><div class="ibpe-s">Select a thread to see its full story. New activity lands here live.</div>' +
      recentPeek() + '</div>';
    var tech = t.tech || {};
    var isIssue = tech.tid && tech.status && tech.status !== 'done';
    var timeline = (t.timeline || []).map(function(e){
      return '<div class="ibtl"><span class="ibtldot"></span><span class="ibtll">' + esc(e.label || e.kind) + '</span>' +
        '<span class="ibtla">' + esc(e.actor || '') + '</span><span class="ibtlw">' + esc(timeAgo(e.at)) + '</span></div>';
    }).join('');
    var actions =
      (isIssue ? '<button class="ibact primary" data-act="redispatch">▸ Re-dispatch fix</button>' +
                 '<button class="ibact" data-act="resolve">Resolve</button>' : '') +
      '<button class="ibact" data-act="archive">' + (t.archived ? 'Unarchive' : 'Archive') + '</button>';
    return '<div class="ibpane">' +
      '<div class="ibph"><div class="ibph-l">' + dot(t.severity) +
        '<div><div class="ibph-t">' + esc(t.title) + '</div>' +
          '<div class="ibph-sub">' + esc(t.actor || 'system') + ' · ' + esc(timeAgo(t.at)) + ' ago</div></div></div></div>' +
      '<div class="ibsum">' + esc(t.snippet || 'No further detail.') + '</div>' +
      (timeline ? '<div class="ibsec"><div class="ibsec-h">Timeline</div>' + timeline + '</div>' : '') +
      '<div class="ibacts">' + actions + '</div>' +
      (isIssue ? '<div class="ibreply"><textarea id="ibReplyT" placeholder="Add a note, then re-dispatch…"></textarea>' +
        '<button class="ibact primary" data-act="replyfix">Send &amp; re-dispatch →</button></div>' : '') +
      (tech.detail || tech.run ? '<details class="ibtech"><summary>Show technical details</summary>' +
        (tech.run ? '<div class="ibtk">run <code>' + esc(String(tech.run)) + '</code></div>' : '') +
        (tech.detail ? '<pre class="ibtd">' + esc(String(tech.detail)) + '</pre>' : '') + '</details>' : '') +
    '</div>';
  }

  function recentPeek(){
    var recent = threads.filter(function(t){ return !t.needs_you; }).slice(0, 4);
    if (!recent.length) return '';
    return '<div class="ibpeek">' + recent.map(function(t){
      return '<div class="ibpeekrow">' + dot(t.severity) + '<span>' + esc(t.title) + '</span><span class="ibpeekw">' + esc(timeAgo(t.at)) + '</span></div>';
    }).join('') + '</div>';
  }

  async function selectThread(sub){
    sel = threads.find(function(t){ return t.subject === sub; }) || null;
    if (sel && !sel.read){ sel.read = true; post('/cloud/inbox/state', { subject: sub, read: true }); }
    paint();
  }

  function paint(){
    var rows = visible();
    var list = rows.length ? rows.map(listRow).join('') : '<div class="ibempty">Nothing here. Try another view.</div>';
    el.innerHTML =
      '<div class="ibx">' +
        '<div class="ibxlist">' + list + '</div>' +
        '<div class="ibxdetail">' + paneFor(sel) + '</div>' +
      '</div>';
    el.querySelectorAll('.ibl').forEach(function(b){ b.onclick = function(){ selectThread(b.getAttribute('data-sub')); }; });
    el.querySelectorAll('.ibact').forEach(function(b){ b.onclick = function(){ doAction(b.getAttribute('data-act'), b); }; });
    if (WB._inboxCounts) WB._inboxCounts();
  }
  WB._inboxRender = paint;

  async function doAction(act, btn){
    if (!sel) return; var tech = sel.tech || {};
    if (act === 'archive'){ var to = !sel.archived; sel.archived = to; await post('/cloud/inbox/state', { subject: sel.subject, archived: to }); if (to) sel = null; await reload(); return; }
    if (act === 'resolve' && tech.tid){ btn.textContent = '…'; await post('/cloud/task/update', { tid: tech.tid, status: 'done' }); await post('/cloud/inbox/state', { subject: sel.subject, cleared: true }); await reload(); return; }
    if (act === 'redispatch' && tech.tid){ btn.textContent = 'running…'; btn.disabled = true; await post('/cloud/task/dispatch', { tid: tech.tid }); await reload(); return; }
    if (act === 'replyfix' && tech.tid){
      var note = (document.getElementById('ibReplyT') || {}).value || '';
      btn.textContent = 'sending…'; btn.disabled = true;
      if (note.trim()) await post('/cloud/task/update', { tid: tech.tid, detail: (tech.detail || '') + '\n\nNote from you: ' + note.trim() });
      await post('/cloud/task/dispatch', { tid: tech.tid }); await reload(); return;
    }
  }

  async function reload(){
    var d = await (await fetch('/cloud/inbox', { credentials: 'same-origin' })).json();
    threads = (d && d.threads) || [];
    if (sel) sel = threads.find(function(t){ return t.subject === sel.subject; }) || null;
    if (WB._paintInboxFunnel) WB._paintInboxFunnel();
    paint();
  }

  // Live push — subscribe to the event bus over SSE (the same /live/:source transport the Studio runs
  // use). Any bus #event pings us; we debounce-refetch the scoped threads. The ping carries no data, so
  // the refresh is always the server-scoped /cloud/inbox. Reconnect is automatic (EventSource builtin).
  var reloadT = null;
  function scheduleReload(){ if (reloadT) return; reloadT = setTimeout(function(){ reloadT = null; if (document.body.contains(el)) reload(); }, 400); }
  function subscribe(){
    if (WB._inboxES){ try { WB._inboxES.close(); } catch(e){} }
    try {
      var es = new EventSource('/live/inbox'); WB._inboxES = es;
      es.onmessage = function(m){ var ev; try { ev = JSON.parse(m.data); } catch(e){ return; } if (ev && ev.type === 'event') scheduleReload(); };
    } catch(e){ /* SSE unavailable → the page still works, just not live */ }
  }

  el.innerHTML = '<div class="ibx"><div class="ibxlist"><div class="ibempty">Loading…</div></div><div class="ibxdetail"></div></div>';
  await reload();
  subscribe();
}});

var ENVELOPE = '<svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="5" width="19" height="14" rx="2"/><path d="M3.2 7L12 13L20.8 7"/></svg>';

WB.scopedStyles('/activity', `
.ibx { display:flex; height:100%; min-height:0; }
.ibxlist { width:380px; flex:none; border-right:1px solid var(--line); overflow:auto; background:var(--bg); }
.ibxdetail { flex:1; overflow:auto; min-width:0; }
.ibempty, .ibpe-s { color:var(--dim); }
.ibempty { padding:30px 20px; font:500 13px var(--read); }

.ibl { display:flex; gap:11px; width:100%; text-align:left; background:transparent; border:0; border-bottom:1px solid var(--line);
  padding:13px 16px; cursor:pointer; align-items:flex-start; }
.ibl:hover { background:var(--hover,rgba(127,127,127,.06)); }
.ibl.on { background:var(--sel,rgba(127,127,127,.10)); }
.ibl.need { box-shadow:inset 3px 0 0 var(--rose,#f4b8c4); }
.ibdot { flex:none; width:9px; height:9px; border-radius:50%; margin-top:5px; background:var(--stroke); }
.ibdot.high { background:var(--rose,#f4b8c4); } .ibdot.med { background:var(--peach,#f4c9a3); } .ibdot.low { background:var(--stroke,#c9ccd3); }
.iblbody { flex:1; min-width:0; display:flex; flex-direction:column; gap:3px; }
.iblrow1 { display:flex; align-items:baseline; gap:8px; }
.iblt { flex:1; min-width:0; font:550 13.5px var(--read); color:var(--ink); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.ibl.unread .iblt { font-weight:700; }
.iblw { flex:none; font:500 11px var(--mono); color:var(--dim); }
.ibls { font:500 12.5px var(--read); color:var(--dim); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.iblmeta { font:500 11px var(--mono); color:var(--dim); }
.iblneed { color:var(--rose,#d8628a); font-weight:600; }

.ibpane { max-width:680px; padding:26px 30px; }
.ibph { margin-bottom:16px; } .ibph-l { display:flex; gap:12px; align-items:flex-start; }
.ibph-l .ibdot { width:11px; height:11px; margin-top:7px; }
.ibph-t { font:650 21px var(--read); letter-spacing:-.01em; color:var(--ink); }
.ibph-sub { font:500 12px var(--mono); color:var(--dim); margin-top:3px; }
.ibsum { font:500 15px var(--read); line-height:1.55; color:var(--ink); background:var(--card); border:1px solid var(--line);
  border-radius:12px; padding:15px 17px; }
.ibsec { margin-top:20px; } .ibsec-h { font:700 10px var(--mono); letter-spacing:.1em; text-transform:uppercase; color:var(--dim); margin-bottom:9px; }
.ibtl { display:flex; align-items:center; gap:9px; padding:5px 0; font:500 13px var(--read); color:var(--ink); }
.ibtldot { width:7px; height:7px; border-radius:50%; background:var(--stroke); flex:none; }
.ibtll { flex:1; } .ibtla { font:500 11px var(--mono); color:var(--dim); } .ibtlw { font:500 11px var(--mono); color:var(--dim); }
.ibacts { display:flex; gap:9px; margin-top:22px; flex-wrap:wrap; }
.ibact { font:600 12.5px var(--read); background:transparent; color:var(--ink); border:1px solid var(--line); border-radius:8px; padding:7px 14px; cursor:pointer; }
.ibact:hover { background:var(--hover,rgba(127,127,127,.06)); }
.ibact.primary { background:var(--mint,#8ad6c8); color:#04221c; border-color:transparent; }
.ibreply { margin-top:14px; display:flex; flex-direction:column; gap:8px; }
.ibreply textarea { font:inherit; font-size:13px; background:var(--card); color:var(--ink); border:1px solid var(--line); border-radius:10px;
  padding:10px 12px; min-height:64px; resize:vertical; }
.ibreply .ibact.primary { align-self:flex-start; }
.ibtech { margin-top:22px; border-top:1px solid var(--line); padding-top:14px; }
.ibtech summary { font:600 12px var(--read); color:var(--dim); cursor:pointer; }
.ibtk { font:500 12px var(--mono); color:var(--dim); margin:10px 0 0; }
.ibtd { font:500 11.5px var(--mono); color:var(--dim); white-space:pre-wrap; background:var(--card); border:1px solid var(--line);
  border-radius:9px; padding:11px 13px; margin:9px 0 0; max-height:220px; overflow:auto; }

.ibpane-empty { display:flex; flex-direction:column; align-items:center; justify-content:center; gap:11px; min-height:60vh; text-align:center; padding:40px; }
.ibpe-ic { color:var(--stroke); } .ibpe-t { font:650 19px var(--read); color:var(--ink); } .ibpe-s { font:500 13px var(--read); max-width:340px; line-height:1.5; }
.ibpeek { margin-top:18px; width:100%; max-width:360px; }
.ibpeekrow { display:flex; align-items:center; gap:9px; padding:6px 0; font:500 12.5px var(--read); color:var(--dim); }
.ibpeekrow span:nth-child(2) { flex:1; text-align:left; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.ibpeekw { font:500 11px var(--mono); }

/* The funnel (left shell sidebar) */
.ibxfunnel { padding:6px 6px; }
.ibxsearch { display:flex; align-items:center; gap:7px; padding:6px 9px; margin:2px 4px 8px; background:var(--card); border:1px solid var(--line); border-radius:9px; }
.ibxsico { color:var(--dim); display:flex; }
.ibxsearch input { flex:1; background:transparent; border:0; outline:0; font:inherit; font-size:13px; color:var(--ink); }
.ibxview { display:flex; align-items:center; gap:9px; width:100%; text-align:left; background:transparent; border:0; border-radius:8px;
  padding:7px 10px; cursor:pointer; font:550 13px var(--read); color:var(--ink); }
.ibxview:hover { background:var(--hover,rgba(127,127,127,.06)); }
.ibxview.on { background:var(--sel,rgba(127,127,127,.10)); font-weight:650; }
.ibxvemoji { width:18px; text-align:center; } .ibxvname { flex:1; }
.ibxvn { font:600 11px var(--mono); color:var(--dim); min-width:14px; text-align:right; }
.railbadge { display:inline-grid; place-items:center; min-width:16px; height:16px; padding:0 4px; border-radius:9px;
  background:var(--rose,#f4b8c4); color:#3a0f1a; font:700 10px var(--mono); margin-left:6px; }
`);
