// wbchat/components/model-selector — composer model picker.
// Registered via registerComposerButton: renders a small dropdown listing ctx.models in the composer
// toolbar (the 'wbc-tool' aesthetic). Items may be strings or { id, label }. Current = ctx.model();
// on change → ctx.setModel(value). Returns null when there are no models to choose from.
// Reference: ai-elements model selector. Self-contained: own CSS themed entirely against --wbc-*.

import { registerComposerButton, el, injectStyle } from '../core.js';

const STYLE = `
  .wbc-modelsel { position: relative; flex: none; }
  .wbc-modelsel-btn { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 8px;
    border: none; background: none; color: var(--wbc-dim); cursor: pointer; border-radius: 8px;
    font: 600 12px var(--wbc-font); max-width: 180px; }
  .wbc-modelsel-btn:hover, .wbc-modelsel.open .wbc-modelsel-btn { background: var(--wbc-line); color: var(--wbc-ink); }
  .wbc-modelsel-lbl { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-modelsel-chev { display: grid; place-items: center; flex: none; color: var(--wbc-dim); transition: transform .15s; }
  .wbc-modelsel.open .wbc-modelsel-chev { transform: rotate(180deg); }
  .wbc-modelsel-chev svg { width: 13px; height: 13px; }

  .wbc-modelsel-menu { position: absolute; bottom: calc(100% + 6px); left: 0; z-index: 30; min-width: 260px;
    max-width: 320px; max-height: 360px; overflow: hidden; border: 1px solid var(--wbc-line);
    background: var(--wbc-panel); border-radius: var(--wbc-radius-sm); box-shadow: 0 8px 24px rgba(0,0,0,.22);
    display: none; }
  .wbc-modelsel.open .wbc-modelsel-menu { display: flex; }
  .wbc-modelsel-grp { display: flex; align-items: center; gap: 7px; font: 700 10px var(--wbc-font); letter-spacing: .05em;
    text-transform: uppercase; color: var(--wbc-dim); padding: 10px 9px 4px; }
  .wbc-modelsel-grp .prov { display: grid; place-items: center; } .wbc-modelsel-grp .prov svg, .wbc-modelsel-grp .prov img { width: 14px; height: 14px; }
  .wbc-modelsel-item { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left;
    border: none; background: none; color: var(--wbc-ink); cursor: pointer; border-radius: 7px;
    padding: 7px 9px; font: 500 13px var(--wbc-font); }
  .wbc-modelsel-item:hover { background: var(--wbc-line); }
  .wbc-modelsel-item .wbc-modelsel-itemlbl { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-modelsel-check { flex: none; width: 14px; display: grid; place-items: center; color: var(--wbc-accent); opacity: 0; }
  .wbc-modelsel-item.on .wbc-modelsel-check { opacity: 1; }
  .wbc-modelsel-check svg { width: 14px; height: 14px; }
  .wbc-modelsel-empty { padding: 12px 10px; font: 500 12px var(--wbc-font); color: var(--wbc-dim); }
  .modbadges { display: inline-flex; align-items: center; gap: 5px; flex: none; color: var(--wbc-dim); }
  .modbadges .modglyph { display: grid; place-items: center; } .modbadges .modglyph svg { width: 13px; height: 13px; }
  .modbadges .modprice { font: 600 10px var(--wbc-font); color: var(--wbc-dim); }
  .modbadges .modctx { font: 600 10px var(--wbc-font); color: var(--wbc-dim); opacity: .8; }
  .modbadges .modarrow { font: 700 11px var(--wbc-font); color: var(--wbc-dim); opacity: .7; margin: 0 -2px; }
`;

const CHEV = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
const CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';

const idOf = (m) => (m && typeof m === 'object') ? m.id : m;
const labelOf = (m) => (m && typeof m === 'object') ? (m.label || m.id) : m;
// A capability's `requires` token → the input modality a model must accept to satisfy it.
const REQ_MODAL = { vision: 'image', image: 'image', audio: 'audio', video: 'video' };
// A model can drive an agent only if it emits text (role "agent"); generators are tools, not brains.
const agentEligible = (m) => (m && m.role) ? m.role === 'agent' : true;

registerComposerButton((ctx) => {
  const models = (ctx.models || []).filter(agentEligible);
  if (models.length === 0) return null;
  injectStyle('model-selector', STYLE);

  const W = (typeof window !== 'undefined') ? window.WB : null;
  const badges = (m) => (W && W.modelBadges) ? W.modelBadges(m) : '';

  // Input modalities the current capability selection demands (e.g. "vision" → the model must accept images).
  function requiredIn() {
    const sel = (ctx.capabilities && ctx.capabilities()) || [];
    const cat = ctx.capabilityCatalog || [];
    const need = {};
    sel.forEach(id => {
      const c = cat.filter(x => x.id === id)[0];
      ((c && c.requires) || []).forEach(r => { const mod = REQ_MODAL[r]; if (mod) need[mod] = 1; });
    });
    return Object.keys(need);
  }
  const modelOk = (m) => { const need = requiredIn(); const hin = (m && m.modal_in) || ['text']; return need.every(k => hin.indexOf(k) >= 0); };
  const available = () => models.filter(modelOk);

  const root = el('div', { class: 'wbc-modelsel' });
  const lbl = el('span', { class: 'wbc-modelsel-lbl' });
  const btn = el('button', {
    class: 'wbc-modelsel-btn', type: 'button', title: 'Select model',
    onClick: (e) => { e.stopPropagation(); toggle(); },
  }, [lbl, el('span', { class: 'wbc-modelsel-chev', html: CHEV })]);
  const menu = el('div', { class: 'wbc-modelsel-menu' });
  root.append(btn, menu);
  // Scrollable list + fixed bottom search (shared shell). Items scroll above the pinned search.
  const shell = ctx.buildMenuShell(menu, { placeholder: 'Search models…', onQuery: () => buildMenu() });

  const provName = (p) => (W && W.providerName) ? W.providerName(p) : (p || '');
  const provIcon = (p) => (W && W.providerIcon) ? W.providerIcon(p) : '';

  function currentLabel() {
    const cur = ctx.model();
    const found = models.find(m => idOf(m) === cur);
    return found != null ? labelOf(found) : labelOf(available()[0] || models[0]);
  }
  function syncLabel() { lbl.textContent = currentLabel(); }

  // When the capability selection changes, the active model may no longer satisfy the required input
  // modalities — fall back to the first model that does so the composer never sits on an invalid brain.
  function sync() {
    const cur = ctx.model();
    const found = models.find(m => idOf(m) === cur);
    if ((!found || !modelOk(found))) {
      const next = available()[0];
      if (next && idOf(next) !== cur) ctx.setModel(idOf(next));
    }
    syncLabel();
  }

  function buildMenu() {
    shell.list.innerHTML = '';
    const cur = ctx.model();
    const q = (shell.input.value || '').trim().toLowerCase();
    const ms = available().filter(m => !q || (labelOf(m) + ' ' + idOf(m) + ' ' + provName(m && m.provider)).toLowerCase().indexOf(q) >= 0);
    if (!ms.length) { shell.list.append(el('div', { class: 'wbc-modelsel-empty' }, requiredIn().length ? 'No model satisfies the selected capabilities.' : 'No models match.')); return; }
    // Group by provider when the models carry one; otherwise a flat list.
    const groups = {}; const order = [];
    ms.forEach(m => { const p = (m && m.provider) || ''; if (!groups[p]) { groups[p] = []; order.push(p); } groups[p].push(m); });
    order.forEach(p => {
      if (p) shell.list.append(el('div', { class: 'wbc-modelsel-grp' }, [el('span', { class: 'prov', html: provIcon(p) }), provName(p)]));
      groups[p].forEach(m => {
        const id = idOf(m);
        shell.list.append(el('button', {
          class: 'wbc-modelsel-item' + (id === cur ? ' on' : ''), type: 'button',
          onClick: (e) => { e.stopPropagation(); ctx.setModel(id); syncLabel(); close(); },
        }, [
          el('span', { class: 'wbc-modelsel-itemlbl' }, labelOf(m)),
          el('span', { class: 'wbc-modelsel-badges', html: badges(m) }),
          el('span', { class: 'wbc-modelsel-check', html: CHECK }),
        ]));
      });
    });
  }

  let onDoc = null;
  function open() {
    shell.input.value = ''; buildMenu();
    root.classList.add('open');
    ctx.menuOpen(close);
    setTimeout(() => shell.input.focus(), 0);
    onDoc = (e) => { if (!root.contains(e.target)) close(); };
    document.addEventListener('click', onDoc);
  }
  function close() {
    root.classList.remove('open');
    ctx.menuClose(close);
    if (onDoc) { document.removeEventListener('click', onDoc); onDoc = null; }
  }
  function toggle() { root.classList.contains('open') ? close() : open(); }

  if (ctx.onChange) ctx.onChange(() => sync());
  if (ctx.onCapabilities) ctx.onCapabilities(() => { sync(); if (root.classList.contains('open')) buildMenu(); });
  sync();
  return root;
});
