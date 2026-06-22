// The "You" surface — a cohesive personal home, decoupled from auth/admin. This is where a person
// builds their identity on a nexus (any nexus — it's nexus-agnostic) and sees what they've actually
// done here: tokens burned, runs launched, and the work they authored that shipped. It folds together
// the editable profile (resource Profile, via /cloud/profile) with live contribution stats. Things that
// are NOT "you" moved out: app/end-user auth + 2FA (gone), custom domains (Admin), backup repo (an
// Integration). What stays: profile, contributions, usage, CLI tokens, preferences, sign-out.

WB.scopedStyles('/profile', `
  .pf-hero { position:relative; display:flex; gap:22px; align-items:flex-start; padding:26px; overflow:hidden; }
  .pf-hero .topdna-bg { position:absolute; inset:0; opacity:.10; pointer-events:none; }
  .pf-av { position:relative; width:96px; height:96px; border-radius:24px; flex:none; display:grid; place-items:center;
    font:800 38px var(--sans); color:var(--on-bloom); border:2px solid var(--stroke); overflow:hidden; cursor:pointer; }
  .pf-av img { width:100%; height:100%; object-fit:cover; }
  .pf-av .cam { position:absolute; inset:0; display:grid; place-items:center; background:rgba(0,0,0,.45);
    color:#fff; font-size:12px; font-weight:700; opacity:0; transition:opacity .15s; }
  .pf-av:hover .cam { opacity:1; }
  .pf-id { flex:1; min-width:0; z-index:1; }
  .pf-name { font:750 26px var(--sans); color:var(--ink); display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .pf-tag { color:var(--dim); font-size:14.5px; margin-top:3px; }
  .pf-bio { color:var(--ink); font-size:13.5px; line-height:1.55; margin-top:12px; max-width:62ch; white-space:pre-wrap; }
  .pf-meta { display:flex; gap:16px; flex-wrap:wrap; margin-top:14px; color:var(--dim); font-size:12.5px; }
  .pf-meta b { color:var(--ink); font-weight:600; }
  .pf-links { display:flex; gap:8px; flex-wrap:wrap; margin-top:12px; }
  .pf-link { display:inline-flex; align-items:center; gap:6px; padding:5px 11px; border:1.5px solid var(--line);
    border-radius:999px; font-size:12.5px; color:var(--ink); text-decoration:none; }
  .pf-link:hover { border-color:var(--ink); }
  .pf-rolebadge { font:700 10px var(--mono); letter-spacing:.07em; text-transform:uppercase; padding:4px 9px;
    border-radius:7px; background:var(--card); border:1.5px solid var(--line); color:var(--dim); }
  .pf-actions { position:absolute; top:18px; right:18px; display:flex; gap:8px; z-index:2; }

  .pf-stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin:16px 0; }
  .pf-stat { padding:16px 18px; border:1px solid var(--line); border-radius:14px; background:var(--card); }
  .pf-stat .n { font:760 30px var(--sans); color:var(--ink); line-height:1; letter-spacing:-.02em; }
  .pf-stat .l { color:var(--dim); font-size:12px; margin-top:7px; text-transform:uppercase; letter-spacing:.04em; font-weight:600; }
  .pf-stat .s { color:var(--faint,var(--dim)); font-size:11.5px; margin-top:3px; }
  .pf-stat .spark { display:flex; align-items:flex-end; gap:3px; height:26px; margin-top:10px; }
  .pf-stat .spark i { flex:1; background:var(--accent,var(--mint)); border-radius:2px 2px 0 0; min-height:2px; opacity:.55; }

  /* ── GitHub-style contribution heatmap ── */
  .cal-card { margin:16px 0; }
  .cal-head { display:flex; align-items:center; justify-content:space-between; gap:14px; flex-wrap:wrap; margin-bottom:14px; }
  .cal-total { font-size:13.5px; color:var(--ink); }
  .cal-total b { font-weight:700; }
  .cal-tabs { display:flex; gap:6px; flex-wrap:wrap; }
  .cal-tab { display:inline-flex; align-items:center; gap:7px; padding:6px 12px; border:1.5px solid var(--line); border-radius:999px;
    background:var(--card); color:var(--dim); font:600 12px var(--sans); cursor:pointer; }
  .cal-tab:hover { border-color:var(--ink); color:var(--ink); }
  .cal-tab.on { color:var(--ink); border-color:var(--mtacc); background:color-mix(in srgb, var(--mtacc) 14%, transparent); }
  .cal-tab .swt { width:9px; height:9px; border-radius:2.5px; background:var(--mtacc); }
  .cal-scroll { width:100%; }
  .cal-grid-wrap { display:grid; grid-template-columns:auto 1fr; column-gap:9px; width:100%; --gap:4px; }
  .cal-months { grid-column:2; grid-row:1; display:grid; grid-auto-flow:column; grid-auto-columns:1fr; column-gap:var(--gap); font-size:10.5px; color:var(--dim); margin-bottom:6px; }
  .cal-months span { white-space:nowrap; }
  .cal-dows { grid-column:1; grid-row:2; display:grid; grid-template-rows:repeat(7,1fr); gap:var(--gap); font-size:10px; color:var(--dim); padding-right:2px; }
  .cal-dows span { display:flex; align-items:center; }
  .cal-grid { grid-column:2; grid-row:2; display:grid; grid-auto-flow:column; grid-auto-columns:1fr; grid-template-rows:repeat(7,1fr); gap:var(--gap); }
  .cal-cell { width:100%; height:100%; border-radius:3px; background:var(--pf-empty); }
  .cal-legend { display:flex; align-items:center; gap:6px; justify-content:flex-end; font-size:10.5px; color:var(--dim); margin-top:12px; }
  .cal-legend i { width:13px; height:13px; border-radius:3px; display:inline-block; }
  [data-theme="dark"] .cal-card { --pf-empty:rgba(255,255,255,.05); }
  [data-theme="light"] .cal-card, .cal-card { --pf-empty:rgba(0,0,0,.05); }

  .pf-sec { scroll-margin-top:20px; }
  .pf-sec h3 { margin:0 0 4px; }
  .pf-sec .sub { color:var(--dim); font-size:12.5px; margin:0 0 14px; }

  .contrib { display:flex; align-items:center; gap:12px; padding:11px 0; border-bottom:1px solid var(--line-soft); }
  .contrib:last-child { border:0; }
  .contrib .dot { width:9px; height:9px; border-radius:50%; flex:none; background:var(--line); }
  .contrib .dot.done { background:var(--live); }
  .contrib .dot.prog { background:var(--blue); }
  .contrib .ct { flex:1; min-width:0; }
  .contrib .ct .t { font-size:13.5px; color:var(--ink); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .contrib .ct .m { font-size:11.5px; color:var(--dim); margin-top:2px; }
  .contrib .st { font:700 10px var(--mono); letter-spacing:.05em; text-transform:uppercase; padding:3px 8px; border-radius:6px;
    border:1.5px solid var(--line); color:var(--dim); flex:none; }
  .contrib .st.done { color:var(--live); border-color:var(--live); }

  .pf-srow { display:flex; align-items:center; gap:14px; padding:9px 0; border-bottom:1px solid var(--line-soft); }
  .pf-srow:last-child { border:0; }
  .pf-srow label { width:120px; color:var(--dim); font-size:13px; flex:none; }
  .pf-input { flex:1; height:36px; padding:0 11px; border:2px solid var(--line); border-radius:8px; background:var(--card);
    color:var(--ink); font:400 14px var(--sans); outline:none; }
  .pf-input:focus { border-color:var(--ink); }
  textarea.pf-input { height:auto; padding:9px 11px; line-height:1.5; resize:vertical; min-height:72px; }
  .pf-swatches { display:flex; gap:8px; flex-wrap:wrap; }
  .pf-sw { width:30px; height:30px; border-radius:9px; cursor:pointer; border:2px solid transparent; }
  .pf-sw.on { border-color:var(--ink); box-shadow:0 0 0 2px var(--paper) inset; }
  .seg { display:flex; border:2px solid var(--stroke); border-radius:9px; overflow:hidden; }
  .seg button { padding:6px 16px; font:600 11px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); background:var(--card); cursor:pointer; }
  .seg button.on { background:var(--ink); color:var(--paper); }
`);

(function () {
  const ACCENTS = ['peach', 'blue', 'mint', 'sky', 'violet', 'cream', 'sage'];

  const def = {
    title: 'You',
    accent: 'var(--peach)',
    async render(el, ctx) {
      const esc = WB.esc || ((s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'));
      const toast = (m, k) => WB.toast(m, k);
      const me = WB.user || { name: 'You', email: '', initial: 'Y' };
      const uid = (me.email || 'me').toLowerCase();

      // ── state ──
      let profile = {};                 // editable layer (resource Profile)
      let stats = { tokens: 0, runs: 0, runs_ok: 0, agents: 0, shipped: 0, open: 0, first_run: null };
      let activity = { tokens: {}, runs: {}, shipped: {}, agents: {} };
      let metric = 'runs';            // which series drives the heatmap
      let contributions = [];
      let editing = false;
      let saving = false;
      let draft = {};                   // staged edits while `editing`
      let tokens = [];                  // CLI PATs
      let tokName = '', minting = false, minted = null;
      let theme = (typeof document !== 'undefined' && document.documentElement.getAttribute('data-theme')) || 'dark';

      // ── data ──
      const api = (path, opts) => fetch(path, Object.assign({ credentials: 'same-origin' }, opts || {}));
      async function load() {
        try {
          const r = await (await api('/cloud/profile?u=' + encodeURIComponent(uid))).json();
          profile = r.profile || {}; stats = r.stats || stats; contributions = r.contributions || [];
          if (r.activity) activity = Object.assign(activity, r.activity);
          // mirror avatar to the shell so the rail "You" tile shows the photo
          try { WB.profile = WB.profile || {}; WB.profile.avatar = profile.avatar || ''; } catch (e2) {}
        } catch (e) {}
        try { tokens = await WB.api.listTokens(); } catch (e) { tokens = []; }
      }

      // ── derived ──
      const displayName = () => (profile.display && profile.display.trim()) || me.name || (me.email ? me.email.split('@')[0] : 'You');
      const initial = () => (displayName()[0] || 'Y').toUpperCase();
      const accentVar = () => 'var(--' + (profile.accent && ACCENTS.includes(profile.accent) ? profile.accent : 'peach') + ')';
      function parseLinks(s) {
        return String(s || '').split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
          const i = l.indexOf('|'); return i < 0 ? { label: l, url: l } : { label: l.slice(0, i).trim(), url: l.slice(i + 1).trim() };
        });
      }
      function fmtNum(n) { n = n || 0; return n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'k' : String(n); }
      function memberSince() {
        if (!stats.first_run) return null;
        const d = new Date(stats.first_run * 1000);
        return d.toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
      }
      function timeAgo(us) {
        if (!us) return ''; const sec = Math.floor(Date.now() / 1000) - Math.floor(us / 1e6);
        if (sec < 60) return 'just now'; if (sec < 3600) return Math.floor(sec / 60) + 'm ago';
        if (sec < 86400) return Math.floor(sec / 3600) + 'h ago'; return Math.floor(sec / 86400) + 'd ago';
      }

      // ── actions ──
      function startEdit() {
        editing = true;
        draft = { display: profile.display || '', tagline: profile.tagline || '', bio: profile.bio || '',
          location: profile.location || '', links: profile.links || '', avatar: profile.avatar || '',
          accent: profile.accent || 'peach' };
        paint();
      }
      function cancelEdit() { editing = false; paint(); }
      async function save() {
        saving = true; paint();
        try {
          const r = await (await api('/cloud/profile', { method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify(Object.assign({ u: uid }, draft)) })).json();
          if (r && r.profile) profile = r.profile;
          editing = false; toast('Profile saved');
          // reflect the new avatar/initial in the shell rail immediately
          try { WB.profile = WB.profile || {}; WB.profile.avatar = profile.avatar || ''; WB.refreshSidebar && WB.refreshSidebar(); } catch (e) {}
        } catch (e) { toast('Could not save'); }
        saving = false; paint();
      }
      function pickAvatar() {
        if (!editing) { startEdit(); }
        const inp = document.createElement('input'); inp.type = 'file'; inp.accept = 'image/*';
        inp.onchange = () => {
          const f = inp.files && inp.files[0]; if (!f) return;
          if (f.size > 1.5e6) { toast('Image too large — keep it under 1.5 MB'); return; }
          const rd = new FileReader();
          rd.onload = () => { draft.avatar = rd.result; paint(); };
          rd.readAsDataURL(f);
        };
        inp.click();
      }
      function setTheme(t) {
        theme = t; document.documentElement.setAttribute('data-theme', t);
        try { localStorage.setItem('wb-theme', t); } catch (e) {}
        paint();
      }
      async function mint() {
        minting = true; paint();
        try { const r = await WB.api.mintToken((tokName || '').trim() || 'cli'); minted = r.token; tokName = '';
          tokens = await WB.api.listTokens(); toast('Token generated — copy it now'); }
        catch (e) { toast('Could not generate token'); }
        minting = false; paint();
      }
      async function revoke(id) {
        try { await WB.api.revokeToken(id); tokens = tokens.filter((t) => t.id !== id); if (minted) minted = null; toast('Token revoked'); }
        catch (e) { toast('Could not revoke'); }
        paint();
      }

      // ── render fragments ──
      function avatarInner(src, init, av) {
        return src ? `<img src="${esc(src)}" alt="">` : esc(init);
      }
      function hero() {
        const src = editing ? draft.avatar : profile.avatar;
        const acc = editing ? ('var(--' + (draft.accent || 'peach') + ')') : accentVar();
        const since = memberSince();
        const links = parseLinks(profile.links);
        const role = (WB.profile && WB.profile.role) || WB.role || 'member';

        const view = `
          <div class="pf-id">
            <div class="pf-name">${esc(displayName())}<span class="pf-rolebadge">${esc(role)}</span></div>
            ${profile.tagline ? `<div class="pf-tag">${esc(profile.tagline)}</div>` : `<div class="pf-tag faint">Add a tagline — say what you build.</div>`}
            ${profile.bio ? `<div class="pf-bio">${esc(profile.bio)}</div>` : ''}
            <div class="pf-meta">
              <span><b>${esc(me.email || '—')}</b></span>
              ${profile.location ? `<span>📍 ${esc(profile.location)}</span>` : ''}
              ${since ? `<span>Active since <b>${esc(since)}</b></span>` : ''}
            </div>
            ${links.length ? `<div class="pf-links">${links.map((l) => `<a class="pf-link" href="${esc(l.url)}" target="_blank" rel="noopener">🔗 ${esc(l.label)}</a>`).join('')}</div>` : ''}
          </div>
          <div class="pf-actions"><button class="btn sm" data-act="edit">Edit profile</button></div>`;

        const edit = `
          <div class="pf-id">
            <div class="pf-srow"><label for="d_display">Name</label><input id="d_display" class="pf-input" value="${esc(draft.display)}" placeholder="${esc(me.name || '')}"></div>
            <div class="pf-srow"><label for="d_tag">Tagline</label><input id="d_tag" class="pf-input" value="${esc(draft.tagline)}" placeholder="What you build, in one line"></div>
            <div class="pf-srow" style="align-items:flex-start"><label for="d_bio" style="margin-top:9px">Bio</label><textarea id="d_bio" class="pf-input" placeholder="A short intro for your team…">${esc(draft.bio)}</textarea></div>
            <div class="pf-srow"><label for="d_loc">Location</label><input id="d_loc" class="pf-input" value="${esc(draft.location)}" placeholder="San Francisco"></div>
            <div class="pf-srow" style="align-items:flex-start"><label for="d_links" style="margin-top:9px">Links</label><textarea id="d_links" class="pf-input" placeholder="GitHub|https://github.com/you&#10;Site|https://you.dev">${esc(draft.links)}</textarea></div>
            <div class="pf-srow"><label>Accent</label><div class="pf-swatches">${ACCENTS.map((a) => `<span class="pf-sw${draft.accent === a ? ' on' : ''}" data-accent="${a}" style="background:var(--${a})" title="${a}"></span>`).join('')}</div></div>
            <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:14px">
              <button class="btn sm" data-act="cancel">Cancel</button>
              <button class="btn sm primary" data-act="save"${saving ? ' disabled' : ''}>${saving ? 'Saving…' : 'Save profile'}</button>
            </div>
          </div>`;

        return `
        <div class="card pf-hero">
          <div class="topdna-bg">${WB.dna ? WB.dna(18, 10) : ''}</div>
          <div class="pf-av" data-act="avatar" style="background:linear-gradient(135deg, ${acc}, var(--blue))">
            ${avatarInner(src, initial())}
            <span class="cam">${editing ? 'Upload' : 'Change'}</span>
          </div>
          ${editing ? edit : view}
        </div>`;
      }

      // ── GitHub-style contribution heatmap ──
      const METRICS = [
        { key: 'tokens', label: 'Tokens used', acc: 'var(--violet)', noun: 'tokens', sum: true },
        { key: 'runs', label: 'Runs launched', acc: 'var(--mint)', noun: 'runs', sum: false },
        { key: 'shipped', label: 'Contributions shipped', acc: 'var(--peach)', noun: 'shipped', sum: false },
        { key: 'agents', label: 'Agents driven', acc: 'var(--sky)', noun: 'agent-days', sum: false }
      ];
      const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      function isoDay(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }

      function calDays() {
        const end = new Date(); end.setHours(0, 0, 0, 0);
        const start = new Date(end); start.setDate(start.getDate() - 363);
        start.setDate(start.getDate() - start.getDay());   // back up to the Sunday → aligned week columns
        const days = []; const d = new Date(start);
        while (d <= end) { days.push(new Date(d)); d.setDate(d.getDate() + 1); }
        return days;
      }
      function levelOf(v, max) { if (!v) return 0; const q = Math.ceil((v / max) * 4); return Math.max(1, Math.min(4, q)); }
      function cellColor(level, acc) {
        if (!level) return 'var(--pf-empty)';
        return `color-mix(in srgb, ${acc} ${[35, 60, 82, 100][level - 1]}%, transparent)`;
      }

      function activityChart() {
        const m = METRICS.find((x) => x.key === metric) || METRICS[0];
        const series = activity[metric] || {};
        const vals = Object.values(series);
        const max = Math.max(1, ...vals);
        const total = vals.reduce((a, b) => a + b, 0);
        const days = calDays();

        const cells = days.map((d) => {
          const key = isoDay(d);
          const v = series[key] || 0;
          const lvl = levelOf(v, max);
          const human = m.sum ? `${v.toLocaleString()} ${m.noun}` : `${v} ${v === 1 ? m.noun.replace(/s$/, '') : m.noun}`;
          const date = MONTHS[d.getMonth()] + ' ' + d.getDate() + ', ' + d.getFullYear();
          return `<span class="cal-cell" style="background:${cellColor(lvl, m.acc)}" title="${esc(human)} on ${esc(date)}"></span>`;
        }).join('');

        // month labels — one grid track per week, label where the month rolls over
        const weeks = Math.ceil(days.length / 7);
        let lastMonth = -1;
        const months = [];
        for (let w = 0; w < weeks; w++) {
          const first = days[w * 7];
          if (first && first.getMonth() !== lastMonth) { lastMonth = first.getMonth(); months.push(`<span>${MONTHS[lastMonth]}</span>`); }
          else months.push('<span></span>');
        }

        const dows = ['', 'Mon', '', 'Wed', '', 'Fri', ''].map((l) => `<span>${l}</span>`).join('');
        const tabs = METRICS.map((x) => `
          <button class="cal-tab${x.key === metric ? ' on' : ''}" data-metric="${x.key}" style="--mtacc:${x.acc}">
            <span class="swt"></span>${esc(x.label)}</button>`).join('');
        const legend = [0, 1, 2, 3, 4].map((l) => `<i style="background:${cellColor(l, m.acc)}"></i>`).join('');
        const totalTxt = m.sum ? total.toLocaleString() : String(total);

        return `
        <div class="card cal-card">
          <div class="cal-head">
            <div class="cal-total"><b>${esc(totalTxt)}</b> ${esc(m.noun)} in the last year</div>
            <div class="cal-tabs">${tabs}</div>
          </div>
          <div class="cal-scroll">
            <div class="cal-grid-wrap">
              <div class="cal-months">${months.join('')}</div>
              <div class="cal-dows">${dows}</div>
              <div class="cal-grid" style="aspect-ratio:${weeks} / 7">${cells}</div>
            </div>
          </div>
          <div class="cal-legend">Less ${legend} More</div>
        </div>`;
      }

      function contribSection() {
        const body = contributions.length ? contributions.map((c) => {
          const done = c.status === 'done';
          const cls = done ? 'done' : (c.status === 'in_progress' ? 'prog' : '');
          return `
          <div class="contrib">
            <span class="dot ${cls}"></span>
            <div class="ct">
              <div class="t">${esc(c.title || c.tid)}</div>
              <div class="m">${esc(c.kind)}${c.agent ? ` · ${esc(c.agent)}` : ''}${c.updated ? ` · ${esc(timeAgo(c.updated))}` : ''}</div>
            </div>
            <span class="st ${done ? 'done' : ''}">${esc((c.status || 'open').replace('_', ' '))}</span>
          </div>`;
        }).join('') : `<div class="faint" style="padding:14px 0;font-size:13px">Nothing authored yet. Work you file or dispatch from Studio shows up here — and what ships gets a ✓.</div>`;
        return `
        <div class="card pf-sec" id="contributions">
          <h3>Contributions</h3>
          <p class="sub">The systems you authored on this nexus — what shipped, and what's in flight.</p>
          ${body}
        </div>`;
      }

      function usageSection() {
        const total = Math.max(stats.tokens, 1);
        return `
        <div class="card pf-sec" id="usage">
          <h3>Usage</h3>
          <p class="sub">Your footprint on this nexus. Org-wide billing &amp; limits live in Admin.</p>
          <div class="kv"><span class="k">Tokens used</span><span class="v">${esc(stats.tokens.toLocaleString())}</span></div>
          <div class="kv"><span class="k">Runs launched</span><span class="v">${esc(String(stats.runs))} (${esc(String(stats.runs_ok))} ok)</span></div>
          <div class="kv"><span class="k">Avg tokens / run</span><span class="v">${esc(stats.runs ? Math.round(stats.tokens / stats.runs).toLocaleString() : '—')}</span></div>
          <div class="kv"><span class="k">Agents driven</span><span class="v">${esc(String(stats.agents))}</span></div>
        </div>`;
      }

      function cliSection() {
        const mintedRow = minted ? `
          <div class="pf-srow"><label>New token</label>
            <span style="display:flex;gap:8px;align-items:center;flex:1;justify-content:flex-end;min-width:0">
              <code class="mono" style="font-size:12px;overflow:hidden;text-overflow:ellipsis">${esc(minted)}</code>
              <button class="btn sm primary" data-act="copyMinted">Copy</button></span></div>
          <p class="faint" style="font-size:12px;margin:6px 0 0">Copy it now — you won't be able to see it again.</p>` : '';
        const list = tokens.length ? `<div style="margin-top:8px">${tokens.map((t) => `
          <div class="kv"><span class="k mono">${esc(t.name)}</span>
            <span style="display:flex;gap:10px;align-items:center"><span class="v faint mono" style="font-size:11.5px">${esc(t.id)}</span>
            <button class="btn sm" data-revoke="${esc(t.id)}">Revoke</button></span></div>`).join('')}</div>` : '';
        return `
        <div class="card pf-sec" id="cli">
          <h3>CLI access</h3>
          <p class="sub">Generate a token, then <code class="mono">work login --token &lt;token&gt;</code> to drive the <code class="mono">work</code> CLI as you — deploy &amp; manage, headless.</p>
          ${mintedRow}
          <div class="pf-srow"><label for="tokname">Name</label>
            <input id="tokname" class="pf-input" placeholder="my-laptop" value="${esc(tokName)}">
            <button class="btn sm primary" data-act="mint"${minting ? ' disabled' : ''}>${minting ? 'Generating…' : 'Generate'}</button></div>
          ${list}
        </div>`;
      }

      function prefsSection() {
        return `
        <div class="card pf-sec" id="prefs">
          <h3>Preferences</h3>
          <p class="sub">How the dashboard looks &amp; behaves for you.</p>
          <div class="pf-srow"><label>Appearance</label>
            <div class="seg" style="margin-left:auto">
              <button class="${theme === 'dark' ? 'on' : ''}" data-theme="dark">Dark</button>
              <button class="${theme === 'light' ? 'on' : ''}" data-theme="light">Light</button>
            </div></div>
          <div style="display:flex;align-items:center;justify-content:space-between;gap:16px;padding-top:14px;margin-top:6px;border-top:1px solid var(--line-soft)">
            <p class="dim" style="font-size:12.5px;margin:0">Done for now? Sign out of this device.</p>
            <a class="btn sm" href="/login/" onclick="return WB.logout && WB.logout()">Sign out</a>
          </div>
        </div>`;
      }

      // ── paint ──
      function paint() {
        el.innerHTML = `
<section>
  <div class="sechead"><div><h2>You</h2><p>Your profile &amp; what you've built on this nexus</p></div></div>
  ${hero()}
  ${activityChart()}
  ${contribSection()}
  ${usageSection()}
  ${cliSection()}
  ${prefsSection()}
</section>`;
        wire();
      }

      function wire() {
        // staged edit inputs (don't repaint on keystroke)
        const bind = (id, key) => { const n = el.querySelector('#' + id); if (n) n.oninput = (e) => { draft[key] = e.target.value; }; };
        bind('d_display', 'display'); bind('d_tag', 'tagline'); bind('d_bio', 'bio'); bind('d_loc', 'location'); bind('d_links', 'links');
        const tn = el.querySelector('#tokname'); if (tn) tn.oninput = (e) => { tokName = e.target.value; };

        el.querySelectorAll('[data-metric]').forEach((b) => b.onclick = () => { metric = b.getAttribute('data-metric'); paint(); });
        el.querySelectorAll('[data-accent]').forEach((s) => s.onclick = () => { draft.accent = s.getAttribute('data-accent'); paint(); });
        el.querySelectorAll('[data-theme]').forEach((b) => b.onclick = () => setTheme(b.getAttribute('data-theme')));
        el.querySelectorAll('[data-revoke]').forEach((b) => b.onclick = () => revoke(b.getAttribute('data-revoke')));

        const acts = {
          edit: startEdit, cancel: cancelEdit, save, avatar: pickAvatar, mint,
          copyMinted: () => { navigator.clipboard && navigator.clipboard.writeText(minted); toast('Token copied'); }
        };
        el.querySelectorAll('[data-act]').forEach((b) => { const fn = acts[b.getAttribute('data-act')]; if (fn) b.onclick = fn; });
      }

      // The shell's "You" sidebar scrolls to a section anchor; honor a pending target.
      function scrollPending() {
        const id = WB._profileSection; WB._profileSection = null;
        if (!id) return; const n = el.querySelector('#' + id); if (n) n.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }

      paint();
      scrollPending();
      await load();
      paint();
      scrollPending();
    }
  };

  WB.view('/profile', def);
  // Back-compat: the old personal page lived at /settings. Keep the route working, pointed at the new You.
  WB.view('/settings', def);
})();
