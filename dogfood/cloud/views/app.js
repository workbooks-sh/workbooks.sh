// In-app browser — apps open HERE, in the content area, not a new tab. A minimal browser chrome
// (back / forward / reload + an editable URL bar) wraps an <iframe> that hosts the app's hosted URL.
// Top-right: an Activity toggle that slides in the app's development activity (changes/deploys/runs).
// THE LINE: this view + the /cloud routes are OUR product (dogfood/cloud), not the open runtime.

WB.view('/app', { title: 'App', fullbleed: true, async render(el){
  var esc = WB.esc;

  // Resolve which app to show: the name is the trailing /app/<name> segment. paintApps() stashes a
  // name→app registry (WB._appReg) when it paints the grid; on a cold deep-link we fetch the feed.
  function nameFromPath(){ var m = (WB.route.path || '').match(/^\/app\/(.+)$/); return m ? decodeURIComponent(m[1]) : null; }
  async function resolveApp(){
    var nm = nameFromPath();
    var reg = WB._appReg || {};
    if (WB._app && (!nm || WB._app.name === nm)) return WB._app;
    if (nm && reg[nm]) return reg[nm];
    try {
      var d = await fetch('/cloud/apps', { credentials: 'same-origin' }).then(function(r){ return r.json(); });
      var apps = (d && d.apps) || [];
      var hit = nm ? apps.filter(function(a){ return a.name === nm; })[0] : apps[0];
      return hit || null;
    } catch (e) { return null; }
  }

  var app = await resolveApp();
  if (!app || !app.url) {
    el.innerHTML = '<div class="abempty"><div class="abempty-ic">' + APP_GLYPH + '</div>' +
      '<div class="abempty-t">App not found</div>' +
      '<div class="abempty-s">Pick an app from the sidebar to open it here.</div>' +
      '<button class="btn sm" data-nav="/">Back to apps</button></div>';
    return;
  }
  WB._app = app;

  // Our own history stack — an iframe to a hosted (often cross-origin) app won't let us read its
  // history, so back/forward/reload drive iframe.src from a stack we own. The URL bar reflects it.
  var hist = [app.url], hi = 0;
  function cur(){ return hist[hi]; }

  el.innerHTML =
    '<div class="appbrowser">' +
      '<div class="abchrome">' +
        '<div class="abnav">' +
          '<button class="abbtn" data-ab-back title="Back" aria-label="Back">' + IC_BACK + '</button>' +
          '<button class="abbtn" data-ab-fwd title="Forward" aria-label="Forward">' + IC_FWD + '</button>' +
          '<button class="abbtn" data-ab-reload title="Reload" aria-label="Reload">' + IC_RELOAD + '</button>' +
        '</div>' +
        '<form class="aburl" data-ab-form>' +
          '<span class="aburl-ico">' + IC_LOCK + '</span>' +
          '<input class="aburl-in" data-ab-url spellcheck="false" autocomplete="off" />' +
        '</form>' +
        '<button class="abbtn abact" data-ab-activity title="App activity" aria-label="App activity">' + IC_ACT + '<span class="ablabel">Activity</span></button>' +
      '</div>' +
      '<div class="abbody">' +
        '<iframe class="abframe" data-ab-frame title="' + esc(app.label || app.name) + '"></iframe>' +
        '<aside class="abpanel" data-ab-panel hidden>' +
          '<div class="abpanel-hd"><span>Activity</span><button class="abpx" data-ab-actclose aria-label="Close">✕</button></div>' +
          '<div class="abpanel-body" data-ab-actbody><div class="abmsg">Loading…</div></div>' +
        '</aside>' +
      '</div>' +
    '</div>';

  var frame = el.querySelector('[data-ab-frame]');
  var urlIn = el.querySelector('[data-ab-url]');
  var panel = el.querySelector('[data-ab-panel]');

  function load(u, push){
    if (push){ hist = hist.slice(0, hi + 1); hist.push(u); hi = hist.length - 1; }
    frame.src = u;
    syncBar();
  }
  function syncBar(){
    urlIn.value = cur();
    el.querySelector('[data-ab-back]').disabled = hi <= 0;
    el.querySelector('[data-ab-fwd]').disabled = hi >= hist.length - 1;
  }

  el.querySelector('[data-ab-back]').onclick = function(){ if (hi > 0){ hi--; frame.src = cur(); syncBar(); } };
  el.querySelector('[data-ab-fwd]').onclick = function(){ if (hi < hist.length - 1){ hi++; frame.src = cur(); syncBar(); } };
  el.querySelector('[data-ab-reload]').onclick = function(){ frame.src = cur(); };
  el.querySelector('[data-ab-form]').onsubmit = function(e){
    e.preventDefault();
    var v = urlIn.value.trim(); if (!v) return;
    if (!/^https?:\/\//i.test(v)) v = 'https://' + v;
    load(v, true);
  };

  // Activity drawer — the app's development trail (changes/deploys/runs). Filter the org activity
  // feed to events that name this app; fall back to the recent feed when nothing matches yet.
  var actLoaded = false;
  function timeAgo(sec){ if (!sec) return ''; var d = Math.floor(Date.now()/1000) - sec;
    return d < 60 ? d+'s' : d < 3600 ? Math.floor(d/60)+'m' : d < 86400 ? Math.floor(d/3600)+'h' : Math.floor(d/86400)+'d'; }
  function paintActivity(){
    var body = el.querySelector('[data-ab-actbody]'); if (!body) return;
    fetch('/cloud/activity', { credentials: 'same-origin' }).then(function(r){ return r.json(); }).then(function(d){
      var all = (d && d.events) || [];
      var key = (app.name || '').toLowerCase(), lbl = (app.label || '').toLowerCase();
      function hits(e){ var s = ((e.target||'')+' '+(e.title||'')+' '+((e.tags||[]).join(' '))).toLowerCase();
        return key && s.indexOf(key) >= 0 || lbl && s.indexOf(lbl) >= 0; }
      var ev = all.filter(hits); var scoped = ev.length > 0; if (!ev.length) ev = all.slice(0, 12);
      if (!ev.length){ body.innerHTML = '<div class="abmsg">No activity yet. Changes, deploys, and runs for this app show up here.</div>'; return; }
      body.innerHTML = (scoped ? '' : '<div class="abnote">No app-specific activity yet — showing recent nexus activity.</div>') +
        ev.map(function(e){
          return '<div class="abev"><span class="abev-ic">' + esc(((e.actor||'?').trim()[0]||'?').toUpperCase()) + '</span>' +
            '<div class="abev-m"><div class="abev-t">' + esc(e.title || e.kind || 'Event') + '</div>' +
            (e.target ? '<div class="abev-s">' + esc(e.target) + '</div>' : '') + '</div>' +
            '<span class="abev-w">' + esc(timeAgo(e.at)) + '</span></div>';
        }).join('');
    }).catch(function(){ body.innerHTML = '<div class="abmsg">Couldn’t load activity.</div>'; });
  }
  function toggleActivity(){
    var open = panel.hasAttribute('hidden');
    if (open){ panel.removeAttribute('hidden'); if (!actLoaded){ actLoaded = true; paintActivity(); } }
    else panel.setAttribute('hidden', '');
    el.querySelector('[data-ab-activity]').classList.toggle('on', open);
  }
  el.querySelector('[data-ab-activity]').onclick = toggleActivity;
  el.querySelector('[data-ab-actclose]').onclick = toggleActivity;

  load(app.url, false);
}});

var APP_GLYPH = '<svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/></svg>';
var IC_BACK = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 18-6-6 6-6"/></svg>';
var IC_FWD = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>';
var IC_RELOAD = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 9-9 9 9 0 0 0-6.74 3.06L3 8"/><path d="M3 3v5h5"/></svg>';
var IC_LOCK = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>';
var IC_ACT = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>';

WB.scopedStyles('/app', `
.appbrowser { height: 100%; min-height: 0; display: flex; flex-direction: column; background: var(--paper); }
.abchrome { flex: none; display: flex; align-items: center; gap: 8px; padding: 8px 10px; border-bottom: 1px solid var(--line); background: var(--card); }
.abnav { display: flex; gap: 2px; }
.abbtn { display: grid; place-items: center; gap: 6px; grid-auto-flow: column; height: 30px; min-width: 30px; padding: 0 7px; border: 1px solid transparent; border-radius: 8px; background: none; color: var(--ink); cursor: pointer; }
.abbtn:hover { background: var(--hover); }
.abbtn:disabled { opacity: .32; cursor: default; background: none; }
.aburl { flex: 1; display: flex; align-items: center; gap: 7px; height: 32px; padding: 0 11px; border: 1px solid var(--line); border-radius: 9px; background: var(--paper); min-width: 0; }
.aburl:focus-within { border-color: var(--stroke); }
.aburl-ico { flex: none; color: var(--dim); display: grid; place-items: center; }
.aburl-in { flex: 1; min-width: 0; border: none; background: none; outline: none; color: var(--ink); font: 500 12.5px var(--mono); }
.abact { border: 1px solid var(--line); }
.abact.on { background: var(--hover); border-color: var(--stroke); }
.ablabel { font: 600 12.5px var(--read); }
.abbody { flex: 1; min-height: 0; display: flex; }
.abframe { flex: 1; min-width: 0; border: 0; background: #fff; }
.abpanel { flex: none; width: 320px; border-left: 1px solid var(--line); background: var(--card); display: flex; flex-direction: column; min-height: 0; }
.abpanel[hidden] { display: none; }
.abpanel-hd { flex: none; display: flex; align-items: center; justify-content: space-between; padding: 12px 14px; border-bottom: 1px solid var(--line); font: 700 11px var(--read); letter-spacing: .07em; text-transform: uppercase; color: var(--dim); }
.abpx { border: none; background: none; color: var(--dim); cursor: pointer; font-size: 14px; line-height: 1; padding: 2px 5px; border-radius: 5px; }
.abpx:hover { background: var(--hover); color: var(--ink); }
.abpanel-body { flex: 1; min-height: 0; overflow-y: auto; padding: 6px; }
.abmsg, .abnote { color: var(--dim); font: 500 12.5px var(--read); padding: 14px; }
.abnote { padding: 8px 10px; font-size: 11.5px; }
.abev { display: flex; align-items: center; gap: 9px; padding: 9px 10px; border-radius: 9px; }
.abev:hover { background: var(--hover); }
.abev-ic { flex: none; width: 26px; height: 26px; border-radius: 8px; display: grid; place-items: center; background: var(--line); color: var(--ink); font: 700 11px var(--read); }
.abev-m { flex: 1; min-width: 0; }
.abev-t { font: 600 13px var(--read); color: var(--ink); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.abev-s { font: 500 11px var(--mono); color: var(--dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 1px; }
.abev-w { flex: none; font: 500 11px var(--mono); color: var(--dim); }
.abempty { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; color: var(--dim); text-align: center; padding: 40px; }
.abempty-ic { color: var(--stroke); }
.abempty-t { font: 600 18px var(--read); color: var(--ink); }
.abempty-s { font: 500 13px var(--read); color: var(--dim); max-width: 320px; }
`);
