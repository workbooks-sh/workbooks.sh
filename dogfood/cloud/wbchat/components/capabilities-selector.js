// wbchat/components/capabilities-selector — composer Capabilities multi-select (Studio).
// Toolkits-as-capabilities plug into the chosen driver agent (per the agents-and-capabilities model).
// Multi-select, gated by the agent's admission: Waldo (:all) → everything selectable; Autopoet (:none) →
// disabled; a list → only those ids. Selected ids thread into the run via ctx.setCapabilities → onSend.

import { registerComposerButton, el, injectStyle } from '../core.js';

const STYLE = `
  .wbc-capsel { position: relative; flex: none; }
  .wbc-capsel-btn { display: inline-flex; align-items: center; gap: 7px; height: 30px; padding: 0 9px;
    border: 1px solid var(--wbc-line); background: var(--wbc-panel); color: var(--wbc-ink); cursor: pointer;
    border-radius: 9px; font: 600 12px var(--wbc-font); }
  .wbc-capsel-btn:hover, .wbc-capsel.open .wbc-capsel-btn { border-color: var(--wbc-accent); }
  .wbc-capsel.disabled .wbc-capsel-btn { cursor: not-allowed; opacity: .5; }
  .wbc-capsel-ct { min-width: 16px; height: 16px; padding: 0 5px; border-radius: 20px; background: var(--wbc-accent);
    color: var(--wbc-panel); font: 700 10px var(--wbc-font); display: grid; place-items: center; }
  .wbc-capsel-chev { display: grid; place-items: center; color: var(--wbc-dim); transition: transform .15s; }
  .wbc-capsel.open .wbc-capsel-chev { transform: rotate(180deg); }
  .wbc-capsel-chev svg { width: 12px; height: 12px; }
  .wbc-capsel-menu { position: absolute; bottom: calc(100% + 6px); left: 0; z-index: 30; min-width: 260px;
    max-width: 320px; max-height: 360px; overflow: hidden; border: 1px solid var(--wbc-line);
    background: var(--wbc-panel); border-radius: var(--wbc-radius-sm); box-shadow: 0 8px 24px rgba(0,0,0,.22); display: none; }
  .wbc-capsel.open .wbc-capsel-menu { display: flex; }
  .wbc-capsel-hd { font: 700 10px var(--wbc-font); letter-spacing: .06em; text-transform: uppercase; color: var(--wbc-dim); padding: 8px 9px 4px; }
  .wbc-capsel-item { display: flex; align-items: center; gap: 9px; width: 100%; text-align: left; border: none;
    background: none; color: var(--wbc-ink); cursor: pointer; border-radius: 8px; padding: 8px 9px; }
  .wbc-capsel-item:hover { background: var(--wbc-line); }
  .wbc-capsel-item.off { opacity: .4; cursor: not-allowed; }
  .wbc-capsel-box { flex: none; width: 16px; height: 16px; border-radius: 5px; border: 1.5px solid var(--wbc-dim); display: grid; place-items: center; color: var(--wbc-panel); }
  .wbc-capsel-item.on .wbc-capsel-box { background: var(--wbc-accent); border-color: var(--wbc-accent); }
  .wbc-capsel-box svg { width: 11px; height: 11px; opacity: 0; }
  .wbc-capsel-item.on .wbc-capsel-box svg { opacity: 1; }
  .wbc-capsel-tt { flex: 1; min-width: 0; }
  .wbc-capsel-lbl { font: 600 13px var(--wbc-font); }
  .wbc-capsel-sub { font: 500 11px var(--wbc-font); color: var(--wbc-dim); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-capsel-empty { padding: 10px 9px; font: 500 12px var(--wbc-font); color: var(--wbc-dim); }
`;

const CHEV = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
const CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
const PLUG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22v-5M9 8V2M15 8V2M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/></svg>';

const nameOf = (a) => (a && typeof a === 'object') ? a.name : a;

registerComposerButton((ctx) => {
  const catalog = (ctx.capabilityCatalog || []).filter(c => c.status === 'ready');
  if (catalog.length === 0) return null;
  injectStyle('capabilities-selector', STYLE);

  const root = el('div', { class: 'wbc-capsel' });
  const ct = el('span', { class: 'wbc-capsel-ct' }, '0');
  const btn = el('button', {
    class: 'wbc-capsel-btn', type: 'button', title: 'Capabilities',
    onClick: (e) => { e.stopPropagation(); if (admission() === 'none') return; toggle(); },
  }, [el('span', { class: 'wbc-capsel-ic', html: PLUG }), el('span', {}, 'Capabilities'), ct,
      el('span', { class: 'wbc-capsel-chev', html: CHEV })]);
  const menu = el('div', { class: 'wbc-capsel-menu' });
  root.append(btn, menu);
  // Scrollable list + fixed bottom search (shared shell). Items scroll above the pinned search.
  const shell = ctx.buildMenuShell(menu, { placeholder: 'Search capabilities…', onQuery: () => buildMenu() });

  function admission() {
    try { return ctx.capabilityAdmission(nameOf(ctx.agent())); } catch (e) { return 'all'; }
  }
  function admits(id) {
    const a = admission();
    return a === 'all' ? true : a === 'none' ? false : (Array.isArray(a) && a.indexOf(id) >= 0);
  }
  function sync() {
    // Drop any selected capabilities the current driver doesn't admit, then refresh the count + state.
    const kept = ctx.capabilities().filter(admits);
    ctx.setCapabilities(kept);
    ct.textContent = String(kept.length);
    ct.style.display = kept.length ? '' : 'none';
    root.classList.toggle('disabled', admission() === 'none');
    btn.title = admission() === 'none' ? 'This agent admits no capabilities' : 'Capabilities';
  }
  function buildMenu() {
    shell.list.innerHTML = '';
    const sel = ctx.capabilities();
    if (admission() === 'none') { shell.list.append(el('div', { class: 'wbc-capsel-empty' }, 'This agent runs sealed — no capabilities.')); return; }
    const q = (shell.input.value || '').trim().toLowerCase();
    const list = catalog.filter(c => !q || ((c.name || '') + ' ' + (c.id || '') + ' ' + (c.blurb || '')).toLowerCase().indexOf(q) >= 0);
    if (!list.length) { shell.list.append(el('div', { class: 'wbc-capsel-empty' }, 'No capabilities match.')); return; }
    list.forEach(c => {
      const ok = admits(c.id), on = sel.indexOf(c.id) >= 0;
      const item = el('button', {
        class: 'wbc-capsel-item' + (on ? ' on' : '') + (ok ? '' : ' off'), type: 'button',
        title: ok ? '' : 'Not admitted by this agent',
        onClick: (e) => { e.stopPropagation(); if (!ok) return;
          const cur = ctx.capabilities(); const i = cur.indexOf(c.id);
          if (i >= 0) cur.splice(i, 1); else cur.push(c.id);
          ctx.setCapabilities(cur); buildMenu(); sync(); },
      }, [
        el('span', { class: 'wbc-capsel-box', html: CHECK }),
        el('div', { class: 'wbc-capsel-tt' }, [
          el('div', { class: 'wbc-capsel-lbl' }, c.name),
          (c.requires && c.requires.length) ? el('div', { class: 'wbc-capsel-sub' }, 'Needs ' + c.requires.join(', ')) :
            (c.blurb ? el('div', { class: 'wbc-capsel-sub' }, c.blurb) : null),
        ].filter(Boolean)),
      ]);
      shell.list.append(item);
    });
  }

  let onDoc = null;
  function open() { shell.input.value = ''; buildMenu(); root.classList.add('open'); ctx.menuOpen(close); setTimeout(() => shell.input.focus(), 0); onDoc = (e) => { if (!root.contains(e.target)) close(); }; document.addEventListener('click', onDoc); }
  function close() { root.classList.remove('open'); ctx.menuClose(close); if (onDoc) { document.removeEventListener('click', onDoc); onDoc = null; } }
  function toggle() { root.classList.contains('open') ? close() : open(); }

  if (ctx.onChange) ctx.onChange(() => sync());
  sync();
  return root;
}, { side: 'left' });
