// routes/workspace/+page.svelte — the workspace STRUCTURE view (the /workspace index tab).
//
// The workspace's .work files as a live code-graph, served from the nexus (GET /:wb/graph → JSON).
// Rendered NATIVELY with @antv/g6 v5 (premium, deep, customizable — no iframe, no D3-blob, not a
// Svelte-Flow editor canvas). Nodes coloured by kind + sized by dependency count; click a node to
// inspect its facets. The surface workspace's id IS the mount the nexus serves it under.
WB.scopedStyles('/workspace', `
  /* ── +layout.svelte (header + tabs) ── */
  .wshead { display:flex; align-items:center; gap:12px; margin-bottom:14px; }
  .wsav {
    width:40px; height:40px; border-radius:11px; flex:none; display:grid; place-items:center;
    background:var(--line); color:var(--ink);
    font:700 16px var(--read);
  }
  .wshead h2 { font-family:var(--display); font-weight:600; font-size:24px; line-height:1.1; color:var(--ink); }
  .wstabs {
    display:flex; gap:2px; margin-bottom:16px;
    border-bottom:1px solid var(--line);
  }
  .wstabs a {
    padding:7px 13px; font:600 13px var(--read); color:var(--dim);
    text-decoration:none; border-bottom:2px solid transparent; margin-bottom:-1px;
    transition:color .1s;
  }
  .wstabs a:hover { color:var(--ink); }
  .wstabs a.on { color:var(--ink); border-bottom-color:var(--section); }

  /* ── structure / graph (native G6) ── */
  .kinds { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:14px; align-items:center; }
  .kpill {
    display:inline-flex; align-items:center; gap:6px; padding:5px 11px; border:1px solid var(--line);
    border-radius:20px; font:500 12.5px var(--read); color:var(--ink); background:var(--card);
  }
  .kpill.total { background:var(--line); }
  .kpill .dot { width:9px; height:9px; border-radius:50%; flex:none; }

  .graphwrap {
    display:grid; grid-template-columns:1fr 300px; gap:0;
    border:1px solid var(--line); border-radius:16px; overflow:hidden; background:var(--card);
    height:66vh; min-height:480px;
  }
  .cyhost { width:100%; height:100%; min-width:0; position:relative;
    background:
      radial-gradient(120% 120% at 50% 0%, color-mix(in srgb, var(--section) 7%, transparent), transparent 60%),
      var(--well); }
  .cyhost canvas { display:block; }
  .cyaside { border-left:1px solid var(--line); padding:18px 20px; overflow-y:auto; }
  .cyaside .empty { color:var(--dim); font:400 13px var(--read); }
  .cyaside .nkind { display:inline-flex; align-items:center; gap:7px; font:700 10px var(--mono);
    letter-spacing:.1em; text-transform:uppercase; color:var(--dim); }
  .cyaside .nkind .sw { width:10px; height:10px; border-radius:50%; }
  .cyaside h3 { font-family:var(--display); font-weight:600; font-size:19px; margin:8px 0 4px; word-break:break-word; }
  .cyaside .row { display:flex; justify-content:space-between; gap:12px; padding:9px 0; border-bottom:1px solid var(--line); font:400 13px var(--read); }
  .cyaside .row:last-of-type { border:0; }
  .cyaside .row .k { color:var(--dim); } .cyaside .row .v { font:500 12px var(--mono); color:var(--ink); text-align:right; word-break:break-all; }
  .cyloading { position:absolute; inset:0; display:grid; place-items:center; color:var(--dim); font:400 13px var(--read); pointer-events:none; }
  .hint { margin-top:10px; font:400 12.5px var(--read); color:var(--dim); }
  .hint code { font:600 11.5px var(--mono); background:var(--line); padding:1px 5px; border-radius:4px; }
  @media (max-width:920px) { .graphwrap { grid-template-columns:1fr; } .cyaside { display:none; } }
`);

WB.view('/workspace', {
  title: 'Workspace',
  accent: 'var(--peach)',
  async render(el, ctx) {
    const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    const ws = WB.ws.active;
    const wsLayoutName = ws?.name || 'Workspace';
    const wsIcon = ws?.icon || (wsLayoutName[0] || 'W').toUpperCase();
    const here = '/workspace';
    const TABS = [
      { href: '/workspace', label: 'Structure' },
      { href: '/workspace/members', label: 'Members & access' },
      { href: '/workspace/sharing', label: 'Sharing' },
      { href: '/workspace/history', label: 'History' },
      { href: '/workspace/env', label: 'Secrets' }
    ];
    const isOn = (href) => (href === '/workspace' ? here === '/workspace' : here === href || here.startsWith(href + '/'));

    function shell(inner) {
      return `
<section>
  <div class="wshead">
    <span class="wsav">${esc(wsIcon)}</span>
    <div><h2>${esc(wsLayoutName)}</h2></div>
  </div>
  <nav class="wstabs">
    ${TABS.map((t) => `<a href="${t.href}"${isOn(t.href) ? ' class="on"' : ''} data-nav="${t.href}">${esc(t.label)}</a>`).join('')}
  </nav>
  ${inner}
</section>`;
    }

    if (!ws) {
      el.innerHTML = shell(`<div class="card faint" style="text-align:center">Pick a workspace from the sidebar.</div>`);
      return;
    }

    // Only a SURFACE workspace (a deployed folder) has a served mount to visualize — a user-created
    // workspace doesn't, so show an honest empty state rather than fetching a 404.
    if (!ws.surface) {
      el.innerHTML = shell(`<div class="card faint" style="text-align:center">This workspace has no deployed surface to visualize yet.</div>`);
      return;
    }

    const mount = (ws.id || '').replace(/^ws_/, '');
    const KIND = { client: '#a8d4f0', server: '#aee5c2', resource: '#f3c5a3', data: '#d9c5f0', design: '#f2ddb0', agent: '#9fc4e8', sandbox: '#c8e0b0', dep: '#5b6b8c' };
    const EDGE = { compose: '#5b6b8c', style: '#f3c5a3', calls: '#aee5c2', imports: '#a8d4f0', fetch: '#f3c5a3', data: '#aee5c2', import: '#a8d4f0', ref: '#d9c5f0', 'work-file': '#c2861f' };

    el.innerHTML = shell(`
  <div class="kinds"><div class="faint" style="font-size:13px">Reading structure…</div></div>
  <div class="graphwrap">
    <div class="cyhost"><div class="cyloading" id="cyloading">Loading graph…</div></div>
    <div class="cyaside" id="cyaside"><div class="empty">Click a node to inspect it.</div></div>
  </div>
  <p class="hint">Each node is a <code>.work</code> unit — colour = kind (client / server / resource / data / design), size = dependencies. Click a node to inspect its declared vs. real facets. Served live from your nexus.</p>`);

    const host = el.querySelector('.cyhost');
    const aside = el.querySelector('#cyaside');

    let summary;
    try {
      const r = await fetch(`/${mount}/graph`, { credentials: 'same-origin' });
      if (!r.ok) throw new Error('graph ' + r.status);
      summary = await r.json();
    } catch (e) {
      el.querySelector('.kinds').innerHTML = `<div class="faint" style="font-size:13px">Couldn’t read the structure (the nexus may be waking — refresh in a moment).</div>`;
      host.innerHTML = '';
      return;
    }

    // kind pills
    let pills = `<div class="kpill total"><b>${summary.units}</b> units</div>`;
    pills += Object.entries(summary.byKind || {})
      .map(([k, n]) => `<div class="kpill"><span class="dot" style="background:${KIND[k] || 'var(--dim)'}"></span><b>${n}</b> ${esc(k)}</div>`)
      .join('');
    if (summary.deps) pills += `<div class="kpill"><span class="dot" style="background:#5b6b8c"></span><b>${summary.deps}</b> deps</div>`;
    el.querySelector('.kinds').innerHTML = pills;

    // load G6 v5
    let G6;
    try {
      G6 = await import('https://cdn.jsdelivr.net/npm/@antv/g6@5/+esm');
    } catch (e) {
      host.innerHTML = `<div class="cyloading">Couldn’t load the graph renderer.</div>`;
      return;
    }
    if (!document.body.contains(host)) return;

    const nodeIds = new Set((summary.nodes || []).map((n) => n.id));
    const byId = {};
    const nodes = (summary.nodes || []).map((n) => { byId[n.id] = n; return { id: n.id, data: { kind: n.kind, lang: n.lang, file: n.file, deps: n.deps || 0, observed: n.observed } }; });
    const edges = (summary.edges || [])
      .filter((e) => nodeIds.has(e.from) && nodeIds.has(e.to))
      .map((e, i) => ({ id: 'e' + i, source: e.from, target: e.to, data: { type: e.type } }));

    const sz = (d) => (d.data && d.data.kind === 'dep') ? 16 : 28 + Math.min((d.data && d.data.deps) || 0, 8) * 6;
    host.querySelector('#cyloading')?.remove();

    const graph = new G6.Graph({
      container: host,
      autoResize: true,
      data: { nodes, edges },
      node: {
        style: {
          fill: (d) => KIND[d.data.kind] || '#8c9189',
          size: sz,
          stroke: 'rgba(255,255,255,.16)', lineWidth: 1.5,
          labelText: (d) => d.id,
          labelFill: '#c9ccc2', labelFontSize: 11, labelFontWeight: 600,
          labelPlacement: 'bottom', labelOffsetY: 4, labelFontFamily: 'Geist, system-ui, sans-serif',
          shadowColor: 'rgba(0,0,0,.35)', shadowBlur: 10
        },
        state: {
          selected: { lineWidth: 3, stroke: '#ecebe5', halo: true, haloOpacity: 0.18 },
          active: { lineWidth: 2.5, stroke: 'rgba(255,255,255,.4)' }
        }
      },
      edge: {
        style: {
          stroke: (d) => EDGE[d.data.type] || '#3a3d42',
          lineWidth: 1.6, opacity: 0.5,
          endArrow: true, endArrowSize: 7
        }
      },
      layout: edges.length
        ? { type: 'd3-force', collide: { radius: 46 }, link: { distance: 120 }, manyBody: { strength: -260 } }
        : { type: 'grid', cols: Math.ceil(Math.sqrt(Math.max(nodes.length, 1))) },
      behaviors: ['zoom-canvas', 'drag-canvas', 'drag-element', 'click-select', 'hover-activate'],
      autoFit: 'view',
      padding: 40
    });

    try { await graph.render(); } catch (e) { host.innerHTML = `<div class="cyloading">Couldn’t draw the graph.</div>`; return; }

    function inspect(id) {
      const n = byId[id]; if (!n) return;
      aside.innerHTML = `
        <span class="nkind"><span class="sw" style="background:${KIND[n.kind] || 'var(--dim)'}"></span>${esc(n.kind)}</span>
        <h3>${esc(n.id)}</h3>
        <div class="row"><span class="k">Language</span><span class="v">${esc(n.lang || '—')}</span></div>
        <div class="row"><span class="k">Dependencies</span><span class="v">${n.deps || 0}</span></div>
        <div class="row"><span class="k">File</span><span class="v">${esc((n.file || '').split('/').pop() || '—')}</span></div>
        <div class="row"><span class="k">Utilization</span><span class="v">${n.observed != null ? esc(String(n.observed)) : '—'}</span></div>`;
    }
    graph.on('node:click', (e) => { const id = e.target && e.target.id; if (id) inspect(id); });
    graph.on('canvas:click', () => { aside.innerHTML = `<div class="empty">Click a node to inspect it.</div>`; });

    // Destroy the G6 instance when navigating away — otherwise its render loop, force simulation and
    // global listeners keep running on the orphaned canvas and freeze the page. The router calls this.
    WB._cleanup = () => { try { graph.destroy(); } catch (e) {} };
  }
});
