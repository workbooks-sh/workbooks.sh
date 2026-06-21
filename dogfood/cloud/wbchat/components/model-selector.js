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

  .wbc-modelsel-menu { position: absolute; bottom: calc(100% + 6px); left: 0; z-index: 30; min-width: 180px;
    max-width: 280px; max-height: 280px; overflow-y: auto; padding: 4px; border: 1px solid var(--wbc-line);
    background: var(--wbc-panel); border-radius: var(--wbc-radius-sm); box-shadow: 0 8px 24px rgba(0,0,0,.22);
    display: none; }
  .wbc-modelsel.open .wbc-modelsel-menu { display: block; }
  .wbc-modelsel-item { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left;
    border: none; background: none; color: var(--wbc-ink); cursor: pointer; border-radius: 7px;
    padding: 7px 9px; font: 500 13px var(--wbc-font); }
  .wbc-modelsel-item:hover { background: var(--wbc-line); }
  .wbc-modelsel-item .wbc-modelsel-itemlbl { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-modelsel-check { flex: none; width: 14px; display: grid; place-items: center; color: var(--wbc-accent); opacity: 0; }
  .wbc-modelsel-item.on .wbc-modelsel-check { opacity: 1; }
  .wbc-modelsel-check svg { width: 14px; height: 14px; }
`;

const CHEV = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
const CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';

const idOf = (m) => (m && typeof m === 'object') ? m.id : m;
const labelOf = (m) => (m && typeof m === 'object') ? (m.label || m.id) : m;

registerComposerButton((ctx) => {
  const models = ctx.models || [];
  if (models.length === 0) return null;
  injectStyle('model-selector', STYLE);

  const root = el('div', { class: 'wbc-modelsel' });
  const lbl = el('span', { class: 'wbc-modelsel-lbl' });
  const btn = el('button', {
    class: 'wbc-modelsel-btn', type: 'button', title: 'Select agent',
    onClick: (e) => { e.stopPropagation(); toggle(); },
  }, [lbl, el('span', { class: 'wbc-modelsel-chev', html: CHEV })]);
  const menu = el('div', { class: 'wbc-modelsel-menu' });
  root.append(btn, menu);

  function currentLabel() {
    const cur = ctx.model();
    const found = models.find(m => idOf(m) === cur);
    return found != null ? labelOf(found) : labelOf(models[0]);
  }
  function syncLabel() { lbl.textContent = currentLabel(); }

  function buildMenu() {
    menu.innerHTML = '';
    const cur = ctx.model();
    models.forEach(m => {
      const id = idOf(m);
      const item = el('button', {
        class: 'wbc-modelsel-item' + (id === cur ? ' on' : ''), type: 'button',
        onClick: (e) => { e.stopPropagation(); ctx.setModel(id); syncLabel(); close(); },
      }, [
        el('span', { class: 'wbc-modelsel-itemlbl' }, labelOf(m)),
        el('span', { class: 'wbc-modelsel-check', html: CHECK }),
      ]);
      menu.append(item);
    });
  }

  let onDoc = null;
  function open() {
    buildMenu();
    root.classList.add('open');
    onDoc = (e) => { if (!root.contains(e.target)) close(); };
    document.addEventListener('click', onDoc);
  }
  function close() {
    root.classList.remove('open');
    if (onDoc) { document.removeEventListener('click', onDoc); onDoc = null; }
  }
  function toggle() { root.classList.contains('open') ? close() : open(); }

  syncLabel();
  return root;
});
