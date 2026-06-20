// Activity — the cloud feed over the nexus reactive layer (events emitted by #event sources, persisted
// by our `log` effect into resource :Event, read from GET /cloud/activity). A tabbed, Twitter-style
// feed (no social): a top tab bar filters the same event stream. Tabs are data-driven + extensible.
// Backfill now; the websocket live-tail is the next layer (same endpoint shape).

WB.view('/activity', { title: 'Activity', accent: 'var(--violet)', fullbleed: true, async render(el){
  var esc = WB.esc;
  // The floating studio rail (shared shell): Create -> Studio (fresh chat), Activity = here. data-nav
  // is handled by the global click delegate in app.js, so plain markup is enough.
  var RAIL_ICONS = {
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>',
    activity: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>'
  };
  function rail(){
    return '<nav class="studio-rail">' +
      '<button class="studio-railbtn" data-tip="Create" aria-label="Create" data-nav="/studio">' + RAIL_ICONS.plus + '</button>' +
      '<button class="studio-railbtn on" data-tip="Activity" aria-label="Activity" data-nav="/activity">' + RAIL_ICONS.activity + '</button>' +
    '</nav>';
  }

  // Extensible tab set: each tab is a label + a predicate over an event. Add a tab = add an entry.
  var TABS = [
    { id: 'all',    label: 'All',    match: function(){ return true; } },
    { id: 'agents', label: 'Agents', match: function(e){ return has(e, 'agent'); } },
    { id: 'team',   label: 'Team',   match: function(e){ return has(e, 'member') || has(e, 'role'); } },
    { id: 'deploys',label: 'Deploys',match: function(e){ return has(e, 'deploy'); } }
  ];
  function has(e, t){ return (e.tags || []).indexOf(t) >= 0 || String(e.kind || '').indexOf(t) === 0; }

  var active = 'all';
  var events = [];

  function timeAgo(sec){
    if (!sec) return '';
    var d = Math.floor(Date.now() / 1000) - sec;
    if (d < 60) return d + 's';
    if (d < 3600) return Math.floor(d / 60) + 'm';
    if (d < 86400) return Math.floor(d / 3600) + 'h';
    return Math.floor(d / 86400) + 'd';
  }
  function initial(s){ return (String(s || '?').trim()[0] || '?').toUpperCase(); }

  function feedItem(e){
    var kind = esc(e.kind || 'event');
    return '<div class="actrow">' +
      '<div class="actav">' + esc(initial(e.actor)) + '</div>' +
      '<div class="actbody">' +
        '<div class="acttop"><span class="actactor">' + esc(e.actor || 'system') + '</span>' +
          '<span class="actkind">' + kind + '</span>' +
          '<span class="acttime">' + esc(timeAgo(e.at)) + '</span></div>' +
        '<div class="acttitle">' + esc(e.title || e.kind || '') + '</div>' +
        (e.target ? '<div class="acttarget">' + esc(e.target) + '</div>' : '') +
      '</div></div>';
  }

  function paint(){
    var tab = TABS.find(function(t){ return t.id === active; }) || TABS[0];
    var shown = events.filter(tab.match);
    el.innerHTML =
      '<div class="studio">' +
        '<div class="studio-scroll"><div class="actwrap">' +
          '<div class="acthd"><h1 class="acttitleh">Activity</h1>' +
            '<p class="actsub">A live feed of everything happening across your nexus.</p></div>' +
          '<div class="acttabs">' + TABS.map(function(t){
            return '<button class="acttab' + (t.id === active ? ' on' : '') + '" data-tab="' + t.id + '">' + esc(t.label) + '</button>';
          }).join('') + '</div>' +
          '<div class="actfeed">' + (shown.length ? shown.map(feedItem).join('') :
            '<div class="actempty">Nothing here yet. As agents run, deploys ship, and your team acts, it shows up here.</div>') + '</div>' +
        '</div></div>' +
        rail() +
      '</div>';
    el.querySelectorAll('[data-tab]').forEach(function(b){
      b.onclick = function(){ active = b.getAttribute('data-tab'); paint(); };
    });
  }

  el.innerHTML = '<div class="studio"><div class="studio-scroll"><div class="actwrap"><div class="actempty">Loading…</div></div></div>' + rail() + '</div>';
  try {
    var r = await fetch('/cloud/activity', { credentials: 'same-origin' });
    var d = await r.json();
    events = (d && d.events) || [];
  } catch (e) { events = []; }
  paint();
}});

WB.scopedStyles('/activity', `
.actwrap { max-width: 720px; }
.acthd { margin-bottom: 16px; }
.acttitleh { font: 700 26px var(--read); letter-spacing: -0.02em; color: var(--ink); margin: 0; }
.actsub { font: 500 13px var(--read); color: var(--dim); margin: 4px 0 0; }
.acttabs { display: flex; gap: 4px; border-bottom: 1px solid var(--line); margin-bottom: 8px; }
.acttab { border: none; background: none; color: var(--dim); cursor: pointer; padding: 9px 12px; font: 600 13px var(--read);
  border-bottom: 2px solid transparent; margin-bottom: -1px; }
.acttab:hover { color: var(--ink); }
.acttab.on { color: var(--ink); border-bottom-color: var(--ink); }
.actfeed { display: flex; flex-direction: column; }
.actrow { display: flex; gap: 12px; padding: 14px 4px; border-bottom: 1px solid var(--line); }
.actav { flex: none; width: 36px; height: 36px; border-radius: 50%; display: grid; place-items: center;
  background: linear-gradient(135deg, var(--violet), var(--sky)); color: #fff; font: 700 14px var(--read); }
.actbody { flex: 1; min-width: 0; }
.acttop { display: flex; align-items: center; gap: 8px; }
.actactor { font: 600 13.5px var(--read); color: var(--ink); }
.actkind { font: 600 10.5px var(--mono); letter-spacing: .04em; text-transform: uppercase; color: var(--dim);
  background: var(--line); border-radius: 5px; padding: 2px 6px; }
.acttime { margin-left: auto; font: 500 12px var(--mono); color: var(--dim); }
.acttitle { font: 500 14px var(--read); color: var(--ink); margin-top: 3px; line-height: 1.4; }
.acttarget { font: 500 12px var(--mono); color: var(--dim); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.actempty { color: var(--dim); font: 500 14px var(--read); padding: 40px 4px; text-align: center; }
`);
