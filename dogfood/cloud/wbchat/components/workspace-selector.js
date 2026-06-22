// wbchat/components/workspace-selector — composer Workspace picker (Studio). Sits to the LEFT of the
// attachment button (right group). Picks the workspace the session runs in ('' = General / system-level);
// locked once the session has messages — you don't move a session out of its workspace. Mutually
// exclusive with the other popovers, with the shared scrollable-list + fixed-bottom-search shell.

import { registerComposerButton, el, injectStyle } from '../core.js';

const STYLE = `
  .wbc-wssel { position: relative; flex: none; }
  .wbc-wssel-btn { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 9px;
    border: 1px solid var(--wbc-line); background: var(--wbc-panel); color: var(--wbc-ink); cursor: pointer;
    border-radius: 9px; font: 600 12px var(--wbc-font); max-width: 170px; }
  .wbc-wssel-btn:hover, .wbc-wssel.open .wbc-wssel-btn { border-color: var(--wbc-accent); }
  .wbc-wssel.locked .wbc-wssel-btn { cursor: default; background: none; border-color: transparent; }
  .wbc-wssel-ic { display: grid; place-items: center; flex: none; color: var(--wbc-dim); } .wbc-wssel-ic svg { width: 13px; height: 13px; }
  .wbc-wssel-lbl { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-wssel-chev { display: grid; place-items: center; flex: none; color: var(--wbc-dim); transition: transform .15s; }
  .wbc-wssel.open .wbc-wssel-chev { transform: rotate(180deg); }
  .wbc-wssel.locked .wbc-wssel-chev { display: none; }
  .wbc-wssel-chev svg { width: 12px; height: 12px; }
  .wbc-wssel-menu { position: absolute; bottom: calc(100% + 6px); left: 0; z-index: 30; min-width: 220px;
    max-width: 300px; max-height: 340px; overflow: hidden; border: 1px solid var(--wbc-line);
    background: var(--wbc-panel); border-radius: var(--wbc-radius-sm); box-shadow: 0 8px 24px rgba(0,0,0,.22); display: none; }
  .wbc-wssel.open .wbc-wssel-menu { display: flex; }
  .wbc-wssel-item { display: flex; align-items: center; gap: 9px; width: 100%; text-align: left; border: none;
    background: none; color: var(--wbc-ink); cursor: pointer; border-radius: 8px; padding: 8px 9px; font: 500 13px var(--wbc-font); }
  .wbc-wssel-item:hover { background: var(--wbc-line); }
  .wbc-wssel-item .wbc-wssel-il { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-wssel-ix { flex: none; display: grid; place-items: center; color: var(--wbc-dim); } .wbc-wssel-ix svg { width: 13px; height: 13px; }
  .wbc-wssel-check { flex: none; width: 14px; display: grid; place-items: center; color: var(--wbc-accent); opacity: 0; }
  .wbc-wssel-item.on .wbc-wssel-check { opacity: 1; }
  .wbc-wssel-check svg { width: 14px; height: 14px; }
  .wbc-wssel-empty { padding: 12px 10px; font: 500 12px var(--wbc-font); color: var(--wbc-dim); }
`;

const CHEV = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
const CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
const HASH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M10 3 6 21M20.5 16H2.5M22 7H4M18 3l-4 18"/></svg>';

registerComposerButton((ctx) => {
  const workspaces = ctx.workspaces || [];
  if (workspaces.length === 0) return null;
  injectStyle('workspace-selector', STYLE);

  const root = el('div', { class: 'wbc-wssel' });
  const lbl = el('span', { class: 'wbc-wssel-lbl' });
  const btn = el('button', {
    class: 'wbc-wssel-btn', type: 'button', title: 'Workspace',
    onClick: (e) => { e.stopPropagation(); if (ctx.workspaceLocked()) return; toggle(); },
  }, [el('span', { class: 'wbc-wssel-ic', html: HASH }), lbl, el('span', { class: 'wbc-wssel-chev', html: CHEV })]);
  const menu = el('div', { class: 'wbc-wssel-menu' });
  root.append(btn, menu);
  const shell = ctx.buildMenuShell(menu, { placeholder: 'Search workspaces…', onQuery: () => buildMenu() });

  const nameOf = (id) => { const w = workspaces.find(x => x.id === id); return w ? w.name : (id || 'General'); };
  function syncLabel() {
    lbl.textContent = nameOf(ctx.workspace());
    root.classList.toggle('locked', !!ctx.workspaceLocked());
    btn.title = ctx.workspaceLocked() ? (nameOf(ctx.workspace()) + ' — locked for this session') : 'Workspace';
  }

  function buildMenu() {
    shell.list.innerHTML = '';
    const cur = ctx.workspace();
    const q = (shell.input.value || '').trim().toLowerCase();
    const list = workspaces.filter(w => !q || (w.name || '').toLowerCase().indexOf(q) >= 0);
    if (!list.length) { shell.list.append(el('div', { class: 'wbc-wssel-empty' }, 'No workspaces match.')); return; }
    list.forEach(w => {
      shell.list.append(el('button', {
        class: 'wbc-wssel-item' + (w.id === cur ? ' on' : ''), type: 'button',
        onClick: (e) => { e.stopPropagation(); ctx.setWorkspace(w.id); syncLabel(); close(); },
      }, [
        el('span', { class: 'wbc-wssel-ix', html: HASH }),
        el('span', { class: 'wbc-wssel-il' }, w.name),
        el('span', { class: 'wbc-wssel-check', html: CHECK }),
      ]));
    });
  }

  let onDoc = null;
  function open() { shell.input.value = ''; buildMenu(); root.classList.add('open'); ctx.menuOpen(close); setTimeout(() => shell.input.focus(), 0); onDoc = (e) => { if (!root.contains(e.target)) close(); }; document.addEventListener('click', onDoc); }
  function close() { root.classList.remove('open'); ctx.menuClose(close); if (onDoc) { document.removeEventListener('click', onDoc); onDoc = null; } }
  function toggle() { root.classList.contains('open') ? close() : open(); }

  if (ctx.onChange) ctx.onChange(() => syncLabel());
  syncLabel();
  return root;
}, { side: 'right' });
