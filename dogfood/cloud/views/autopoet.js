// Autopoet — the admin-only management surface. The autopoet is secluded under admin: this view shows
// and controls its heartbeat (on/off + cadence), what it can ACCESS (managed/frozen agents, ceilings,
// leases), and its LOGS (recent cycle outcomes + learned lessons). Reads/writes the admin-gated
// /cloud/autopoet routes. wb: admin autopoet management.
//
// Unified admin layout: shared .sechead / .stats / .stat / .card / .btn / .tag / table — only the
// heartbeat badge + tag color variants + log list are scoped CSS the shared sheet doesn't cover.

WB.scopedStyles('/autopoet', `
  .ap { max-width:1280px; }
  .apgrid { display:grid; grid-template-columns:repeat(auto-fit, minmax(360px, 1fr)); gap:16px; align-items:start; }
  .apbadge { font:700 11px var(--mono); letter-spacing:.04em; padding:4px 11px; border-radius:999px; }
  .apbadge.on { background:var(--mint); color:#0b3d22; }
  .apbadge.off { background:var(--line); color:var(--dim); }
  .aprow { display:flex; align-items:center; gap:12px; flex-wrap:wrap; }
  select.apsel { height:32px; border:1px solid var(--line); border-radius:9px; padding:0 10px; font:600 12.5px var(--read); background:var(--card); color:var(--ink); cursor:pointer; }
  select.apsel:focus { border-color:var(--ink); box-shadow:var(--soft-1); }
  .tag.managed { background:var(--mint); color:#0b3d22; border-color:transparent; }
  .tag.proposed { background:var(--cream); color:#5a4a12; border-color:transparent; }
  .tag.frozen { background:var(--peach); color:#7a3310; border-color:transparent; }
  ul.aplog { list-style:none; margin:0; padding:0; font:400 13px var(--read); }
  ul.aplog li { padding:9px 0; border-bottom:1px dashed var(--line); }
  ul.aplog li:last-child { border-bottom:none; }
  ul.aplog .topic { font:700 11px var(--mono); color:var(--violet); margin-right:8px; }
  .apmut { color:var(--dim); }
  .apwarn { color:var(--peach, #b5651d); font-size:12.5px; margin:10px 0 0; }
`);

WB.view('/autopoet', {
  title: 'Autopoet',
  accent: 'var(--violet)',
  async render(el) {
    const esc = WB.esc;

    // Seclude: admin only. Non-admins are bounced to the denied surface.
    if (!WB.can('autopoet.manage')) { WB.nav('/denied'); return; }

    const fmtNext = (ms) => ms == null ? '—' : (ms < 60000 ? Math.round(ms / 1000) + 's' : Math.round(ms / 60000) + 'm');
    const ago = (sec) => { if (!sec) return ''; const d = Math.max(0, Math.floor(Date.now() / 1000 - sec)); return d < 60 ? d + 's ago' : d < 3600 ? Math.floor(d / 60) + 'm ago' : Math.floor(d / 3600) + 'h ago'; };

    async function load() {
      let d;
      try { d = await (await fetch('/cloud/autopoet?role=' + encodeURIComponent(WB.role), { credentials: 'same-origin' })).json(); }
      catch (e) { el.innerHTML = '<section class="ap"><div class="card apmut">Could not load autopoet status.</div></section>'; return; }
      if (d && d.error) { WB.nav('/denied'); return; }
      paint(d);
    }

    async function act(path, body) {
      try {
        await fetch('/cloud/autopoet' + path, {
          method: 'POST', credentials: 'same-origin',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(Object.assign({ role: WB.role }, body || {}))
        });
      } catch (e) { WB.toast && WB.toast('Action failed', 'bad'); }
      await load();
    }

    function paint(d) {
      const hb = (d && d.heartbeat) || {};
      const ac = (d && d.access) || { agents: [], leases: [], impure_indexes: [] };
      const log = (d && d.log) || [];
      const last = hb.last;
      const every = hb.every || '15m';

      const opt = (v, lbl) => '<option value="' + v + '"' + (every === v ? ' selected' : '') + '>' + lbl + '</option>';

      const agents = (ac.agents || []).map(a =>
        '<tr><td><b>' + esc(a.name) + '</b></td>' +
        '<td><span class="tag ' + esc(a.management) + '">' + esc(a.management) + '</span></td>' +
        '<td class="apmut">' + esc(a.ceiling) + '</td></tr>'
      ).join('') || '<tr><td colspan="3" class="apmut">No agents registered.</td></tr>';

      const leases = (ac.leases || []).map(l =>
        '<li><span class="topic">' + esc(l.principal) + '</span> ' + esc(l.cap) + ' <span class="apmut">(lease)</span></li>'
      ).join('') || '<li class="apmut">No active leases.</li>';

      const lessons = (log || []).map(e =>
        '<li><span class="topic">' + esc(e.topic) + '</span>' + esc(e.lesson) +
        (e.evidence ? ' <span class="apmut">· ' + esc(e.evidence) + '</span>' : '') + '</li>'
      ).join('') || '<li class="apmut">No lessons learned yet.</li>';

      const lastSummary = last
        ? ('sensed ' + (last.sensed || 0) + ' · ' + ((last.results || []).length) + ' routed ' + (last.at ? '· ' + ago(last.at) : ''))
        : 'never run';

      const impure = (ac.impure_indexes || []);

      el.innerHTML =
        '<section class="ap">' +

        // ── Compact unified header: title + subtitle + the on/off toggle ──
        '<div class="sechead"><div>' +
            '<h2>Autopoet</h2>' +
            '<p>The autonomous maintainer — heartbeat, what it may edit, and what it has learned.</p>' +
          '</div>' +
          '<button class="btn sm ' + (hb.armed ? 'danger' : 'primary') + '" data-act="' + (hb.armed ? 'off' : 'on') + '">' +
            (hb.armed ? 'Turn off' : 'Turn on') + '</button>' +
        '</div>' +

        // ── Status stats grid ──
        '<div class="stats">' +
          '<div class="stat"><div class="k">Heartbeat</div><div class="v" style="font-size:18px"><span class="apbadge ' + (hb.armed ? 'on">ON' : 'off">OFF') + '</span></div><div class="d apmut">' + (hb.armed ? 'every ' + esc(every) : 'paused') + '</div></div>' +
          '<div class="stat"><div class="k">Next beat</div><div class="v">' + (hb.armed ? esc(fmtNext(hb.next_ms)) : '—') + '</div><div class="d apmut">' + (hb.armed ? 'until next cycle' : 'not armed') + '</div></div>' +
          '<div class="stat"><div class="k">Managed</div><div class="v">' + (ac.managed || 0) + '</div><div class="d apmut">' + (ac.proposed || 0) + ' proposed · ' + (ac.frozen || 0) + ' frozen</div></div>' +
          '<div class="stat"><div class="k">Leases</div><div class="v">' + ((ac.leases || []).length) + '</div><div class="d apmut">active grants</div></div>' +
        '</div>' +

        '<div class="apgrid">' +

          // ── Heartbeat controls ──
          '<div class="card">' +
            '<h3>Heartbeat</h3>' +
            '<div class="aprow">' +
              '<select class="apsel" data-cadence>' + opt('5m', 'every 5m') + opt('15m', 'every 15m') + opt('1h', 'every 1h') + opt('6h', 'every 6h') + '</select>' +
              '<span class="apmut" style="font-size:12.5px">' + (hb.armed ? 'next beat in ' + esc(fmtNext(hb.next_ms)) : 'paused') + '</span>' +
              '<span style="flex:1"></span>' +
              '<button class="btn sm" data-act="run">Run once now</button>' +
            '</div>' +
            '<p class="note" style="margin-top:14px">Last cycle: ' + esc(lastSummary) + '</p>' +
          '</div>' +

          // ── Logs & learning ──
          '<div class="card">' +
            '<h3>Logs &amp; learning</h3>' +
            '<ul class="aplog">' + lessons + '</ul>' +
          '</div>' +

          // ── Access (full-width-ish: agents + leases) ──
          '<div class="card" style="grid-column:1 / -1">' +
            '<h3>Access</h3>' +
            '<p class="note">What the autopoet may edit. Frozen agents and impure indexes are off-limits.</p>' +
            (impure.length ? '<div class="apwarn">⚠ ' + impure.length + ' impure index(es) — not autonomously editable: ' + esc(impure.join(', ')) + '</div>' : '') +
            '<table style="margin-top:14px"><thead><tr><th>Agent</th><th>Management</th><th>Ceiling</th></tr></thead><tbody>' + agents + '</tbody></table>' +
            '<h3 style="margin:20px 0 10px;font-size:14px">Active leases</h3>' +
            '<ul class="aplog">' + leases + '</ul>' +
          '</div>' +

        '</div>' +
        '</section>';

      // wire actions
      const cadence = el.querySelector('[data-cadence]');
      el.querySelectorAll('[data-act]').forEach(b => b.addEventListener('click', () => {
        const a = b.getAttribute('data-act');
        if (a === 'on') act('/heartbeat', { on: true, every: cadence ? cadence.value : '15m' });
        else if (a === 'off') act('/heartbeat', { on: false });
        else if (a === 'run') act('/run', {});
      }));
      if (cadence) cadence.addEventListener('change', () => { if (hb.armed) act('/heartbeat', { on: true, every: cadence.value }); });
    }

    el.innerHTML = '<section class="ap"><div class="card apmut">Loading the autopoet…</div></section>';
    await load();
  }
});
