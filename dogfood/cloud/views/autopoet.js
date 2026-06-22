// Autopoet — the admin-only management surface. The autopoet is secluded under admin: this view shows
// and controls its heartbeat (on/off + cadence), what it can ACCESS (managed/frozen agents, ceilings,
// leases), and its LOGS (recent cycle outcomes + learned lessons). Reads/writes the admin-gated
// /cloud/autopoet routes. wb: admin autopoet management.

WB.scopedStyles('/autopoet', `
  .ap-wrap { max-width:880px; }
  .ap-card { border:1px solid var(--line); border-radius:12px; background:var(--card); padding:18px 20px; margin:0 0 16px; }
  .ap-head { display:flex; align-items:center; justify-content:space-between; gap:14px; margin:0 0 14px; }
  .ap-h { font:700 13px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); margin:0; }
  .ap-badge { font:700 11px var(--mono); letter-spacing:.04em; padding:3px 9px; border-radius:999px; }
  .ap-on { background:var(--mint); color:#0b3d22; }
  .ap-off { background:var(--line); color:var(--dim); }
  .ap-row { display:flex; align-items:center; gap:12px; flex-wrap:wrap; }
  .ap-stat { display:flex; gap:24px; flex-wrap:wrap; margin:6px 0 2px; }
  .ap-stat .n { font:700 22px var(--sans); color:var(--ink); }
  .ap-stat .k { font:600 11px var(--mono); text-transform:uppercase; letter-spacing:.04em; color:var(--dim); }
  .ap-btn { border:1px solid var(--line); background:var(--paper); color:var(--ink); border-radius:8px; padding:7px 14px; font:600 13px var(--sans); cursor:pointer; }
  .ap-btn:hover { border-color:var(--ink); }
  .ap-btn.primary { background:var(--ink); color:var(--paper); border-color:var(--ink); }
  .ap-btn:disabled { opacity:.5; cursor:default; }
  select.ap-sel { border:1px solid var(--line); border-radius:8px; padding:7px 10px; font:600 13px var(--sans); background:var(--paper); color:var(--ink); }
  table.ap-tbl { width:100%; border-collapse:collapse; font:400 13px var(--read); }
  table.ap-tbl th { text-align:left; padding:8px 10px; font:700 10.5px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); border-bottom:1px solid var(--line); }
  table.ap-tbl td { padding:9px 10px; border-bottom:1px solid var(--line); }
  table.ap-tbl tr:last-child td { border-bottom:none; }
  .tag { font:700 10.5px var(--mono); padding:2px 8px; border-radius:999px; }
  .tag.managed { background:var(--mint); color:#0b3d22; }
  .tag.proposed { background:var(--cream); color:#5a4a12; }
  .tag.frozen { background:var(--peach); color:#7a3310; }
  .ap-log { font:400 12.5px var(--read); }
  .ap-log li { padding:7px 0; border-bottom:1px dashed var(--line); list-style:none; }
  .ap-log .topic { font:700 11px var(--mono); color:var(--violet); margin-right:8px; }
  .ap-mut { color:var(--dim); font-size:12.5px; }
  .ap-warn { color:var(--peach, #b5651d); }
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
      catch (e) { el.innerHTML = '<div class="ap-wrap"><div class="ap-card">Could not load autopoet status.</div></div>'; return; }
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
        '<td class="ap-mut">' + esc(a.ceiling) + '</td></tr>'
      ).join('') || '<tr><td colspan="3" class="ap-mut">No agents registered.</td></tr>';

      const leases = (ac.leases || []).map(l =>
        '<li><span class="topic">' + esc(l.principal) + '</span> ' + esc(l.cap) + ' <span class="ap-mut">(lease)</span></li>'
      ).join('') || '<li class="ap-mut">No active leases.</li>';

      const lessons = (log || []).map(e =>
        '<li><span class="topic">' + esc(e.topic) + '</span>' + esc(e.lesson) +
        (e.evidence ? ' <span class="ap-mut">· ' + esc(e.evidence) + '</span>' : '') + '</li>'
      ).join('') || '<li class="ap-mut">No lessons learned yet.</li>';

      const lastSummary = last
        ? ('sensed ' + (last.sensed || 0) + ' · ' + ((last.results || []).length) + ' routed ' + (last.at ? '· ' + ago(last.at) : ''))
        : 'never run';

      const impure = (ac.impure_indexes || []);

      el.innerHTML =
        '<div class="ap-wrap">' +

        // ── Heartbeat ──
        '<div class="ap-card">' +
          '<div class="ap-head"><h3 class="ap-h">Heartbeat</h3>' +
            '<span class="ap-badge ' + (hb.armed ? 'ap-on">ON' : 'ap-off">OFF') + '</span></div>' +
          '<div class="ap-row">' +
            '<button class="ap-btn ' + (hb.armed ? '' : 'primary') + '" data-act="' + (hb.armed ? 'off' : 'on') + '">' +
              (hb.armed ? 'Turn off' : 'Turn on') + '</button>' +
            '<select class="ap-sel" data-cadence>' + opt('5m', 'every 5m') + opt('15m', 'every 15m') + opt('1h', 'every 1h') + opt('6h', 'every 6h') + '</select>' +
            '<span class="ap-mut">' + (hb.armed ? 'next beat in ' + fmtNext(hb.next_ms) : 'paused') + '</span>' +
            '<span style="flex:1"></span>' +
            '<button class="ap-btn" data-act="run">Run once now</button>' +
          '</div>' +
          '<div class="ap-mut" style="margin-top:10px">Last cycle: ' + esc(lastSummary) + '</div>' +
        '</div>' +

        // ── Access ──
        '<div class="ap-card">' +
          '<div class="ap-head"><h3 class="ap-h">Access</h3>' +
            '<span class="ap-mut">what the autopoet may edit</span></div>' +
          '<div class="ap-stat">' +
            '<div><div class="n">' + (ac.managed || 0) + '</div><div class="k">managed</div></div>' +
            '<div><div class="n">' + (ac.proposed || 0) + '</div><div class="k">proposed</div></div>' +
            '<div><div class="n">' + (ac.frozen || 0) + '</div><div class="k">frozen</div></div>' +
            '<div><div class="n">' + ((ac.leases || []).length) + '</div><div class="k">leases</div></div>' +
          '</div>' +
          (impure.length ? '<div class="ap-warn" style="margin:8px 0">⚠ ' + impure.length + ' impure index(es) — not autonomously editable: ' + esc(impure.join(', ')) + '</div>' : '') +
          '<table class="ap-tbl" style="margin-top:8px"><thead><tr><th>Agent</th><th>Management</th><th>Ceiling</th></tr></thead><tbody>' + agents + '</tbody></table>' +
          '<div class="ap-h" style="margin:16px 0 8px">Active leases</div><ul class="ap-log">' + leases + '</ul>' +
        '</div>' +

        // ── Logs ──
        '<div class="ap-card">' +
          '<div class="ap-head"><h3 class="ap-h">Logs &amp; learning</h3></div>' +
          '<ul class="ap-log">' + lessons + '</ul>' +
        '</div>' +

        '</div>';

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

    el.innerHTML = '<div class="ap-wrap"><div class="ap-card ap-mut">Loading the autopoet…</div></div>';
    await load();
  }
});
