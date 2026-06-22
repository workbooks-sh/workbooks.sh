// Activity — INBOX + CONTEXT (progressive disclosure). The inbox list lives in the shell sidebar
// (paintActivity in app.js, fed by GET /cloud/activity). THIS view is the PAGE: it renders the
// context of the event the user selected in the inbox (WB._activityFocus), defaulting to the newest.
// Clicking an inbox row sets WB._activityFocus and calls WB._activityRender — no full nav.

WB.view('/activity', { title: 'Activity', accent: 'var(--violet)', async render(el){
  var esc = WB.esc;
  function timeAgo(sec){
    if (!sec) return '';
    var d = Math.floor(Date.now() / 1000) - sec;
    if (d < 60) return d + 's ago'; if (d < 3600) return Math.floor(d / 60) + 'm ago';
    if (d < 86400) return Math.floor(d / 3600) + 'h ago'; return Math.floor(d / 86400) + 'd ago';
  }
  function initial(s){ return (String(s || '?').trim()[0] || '?').toUpperCase(); }

  // Render the focused event's full context into the page. Registered on WB so the sidebar inbox
  // (app.js) can re-render the pane in place when a row is clicked, without a route change.
  WB._activityRender = function(focus){
    var events = WB._activityEvents || [];
    if (!events.length) {
      el.innerHTML = '<div class="actx-empty"><div class="actx-empty-ic">' + ACT_GLYPH + '</div>' +
        '<div class="actx-empty-t">No activity yet</div>' +
        '<div class="actx-empty-s">As agents run, deploys ship, and your team acts, it shows up here.</div></div>';
      return;
    }
    if (focus == null) {
      el.innerHTML = '<div class="actx-empty"><div class="actx-empty-ic">' + ACT_GLYPH + '</div>' +
        '<div class="actx-empty-t">Select an event</div>' +
        '<div class="actx-empty-s">Choose an item from the inbox on the left to see its full context.</div></div>';
      return;
    }
    var i = Math.max(0, Math.min(focus || 0, events.length - 1));
    var e = events[i];
    var actions = [];
    if (e.target) actions.push({ label: 'Open ' + e.target, nav: null });
    el.innerHTML =
      '<div class="actx">' +
        '<div class="actx-head">' +
          '<div class="actx-av">' + esc(initial(e.actor)) + '</div>' +
          '<div><div class="actx-title">' + esc(e.title || e.kind || 'Event') + '</div>' +
            '<div class="actx-sub"><span class="actx-kind">' + esc(e.kind || 'event') + '</span> · ' +
              esc(e.actor || 'system') + ' · ' + esc(timeAgo(e.at)) + '</div></div>' +
        '</div>' +
        (e.target ? '<div class="actx-body"><div class="actx-label">Target</div><div class="actx-target">' + esc(e.target) + '</div></div>' : '') +
        ((e.tags && e.tags.length) ? '<div class="actx-tags">' + e.tags.map(function(t){ return '<span class="actx-tag">' + esc(t) + '</span>'; }).join('') + '</div>' : '') +
      '</div>';
  };

  el.innerHTML = '<div class="actx-empty">Loading…</div>';
  // Share the same fetch+cache as the sidebar inbox so indices line up.
  await WB.swr('activity', function(){ return fetch('/cloud/activity', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
    WB._activityEvents = (d && d.events) || [];
  });
  WB._activityRender(WB._activityFocus);
}});

var ACT_GLYPH = '<svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>';

WB.scopedStyles('/activity', `
.actx { max-width: 640px; }
.actx-head { display: flex; gap: 14px; align-items: center; margin-bottom: 20px; }
.actx-av { flex: none; width: 48px; height: 48px; border-radius: 13px; display: grid; place-items: center;
  background: linear-gradient(135deg, var(--violet), var(--sky)); color: #1a1430; font: 700 18px var(--read); }
.actx-title { font: 600 22px var(--read); letter-spacing: -0.01em; color: var(--ink); }
.actx-sub { font: 500 12px var(--mono); color: var(--dim); margin-top: 3px; }
.actx-kind { text-transform: uppercase; letter-spacing: .04em; }
.actx-body { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px 18px; }
.actx-label { font: 700 10px var(--mono); letter-spacing: .1em; text-transform: uppercase; color: var(--dim); margin-bottom: 6px; }
.actx-target { font: 500 14px var(--mono); color: var(--ink); }
.actx-tags { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 14px; }
.actx-tag { font: 600 11px var(--mono); color: var(--dim); background: var(--line); border-radius: 6px; padding: 3px 8px; }
.actx-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 11px; min-height: 56vh; text-align: center; padding: 40px; color: var(--dim); }
.actx-empty-ic { color: var(--stroke); }
.actx-empty-t { font: 600 20px var(--read); color: var(--ink); }
.actx-empty-s { font: 500 13.5px var(--read); color: var(--dim); max-width: 360px; line-height: 1.5; }
`);
