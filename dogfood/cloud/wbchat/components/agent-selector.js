// wbchat/components/agent-selector — composer agent picker (Studio).
// Mirrors the model selector, but for the AGENT the run is routed through. Each agent shows its pastel
// chip (WB.AGENT_THEME, shared with the Toolkits page) + label. The agent is chosen ONLY when starting a
// session: once the conversation has any messages, ctx.agentLocked() is true and the control collapses to
// a static, non-interactive label of the pinned agent. Re-evaluates on every ctx.onChange (message change).
// Items are { name, label, toolkit } records; current = ctx.agent(); on change → ctx.setAgent(name).

import { registerComposerButton, el, injectStyle } from '../core.js';

const STYLE = `
  .wbc-agentsel { position: relative; flex: none; }
  .wbc-agentsel-btn { display: inline-flex; align-items: center; gap: 7px; height: 30px; padding: 0 9px 0 7px;
    border: 1px solid var(--wbc-line); background: var(--wbc-panel); color: var(--wbc-ink); cursor: pointer;
    border-radius: 9px; font: 600 12px var(--wbc-font); max-width: 200px; }
  .wbc-agentsel-btn:hover, .wbc-agentsel.open .wbc-agentsel-btn { border-color: var(--wbc-accent); }
  .wbc-agentsel.locked .wbc-agentsel-btn { cursor: default; background: none; border-color: transparent; }
  .wbc-agentsel-ic { width: 18px; height: 18px; border-radius: 6px; flex: none; display: grid; place-items: center; }
  .wbc-agentsel-ic svg { width: 13px; height: 13px; }
  .wbc-agentsel-lbl { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-agentsel-chev { display: grid; place-items: center; flex: none; color: var(--wbc-dim); transition: transform .15s; }
  .wbc-agentsel.open .wbc-agentsel-chev { transform: rotate(180deg); }
  .wbc-agentsel.locked .wbc-agentsel-chev { display: none; }
  .wbc-agentsel-chev svg { width: 12px; height: 12px; }

  .wbc-agentsel-menu { position: absolute; bottom: calc(100% + 6px); left: 0; z-index: 30; min-width: 230px;
    max-width: 300px; max-height: 320px; overflow-y: auto; padding: 4px; border: 1px solid var(--wbc-line);
    background: var(--wbc-panel); border-radius: var(--wbc-radius-sm); box-shadow: 0 8px 24px rgba(0,0,0,.22);
    display: none; }
  .wbc-agentsel.open .wbc-agentsel-menu { display: block; }
  .wbc-agentsel-item { display: flex; align-items: center; gap: 9px; width: 100%; text-align: left;
    border: none; background: none; color: var(--wbc-ink); cursor: pointer; border-radius: 8px; padding: 8px 9px; }
  .wbc-agentsel-item:hover { background: var(--wbc-line); }
  .wbc-agentsel-itemtt { flex: 1; min-width: 0; }
  .wbc-agentsel-itemlbl { font: 600 13px var(--wbc-font); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-agentsel-itemsub { font: 500 11px var(--wbc-font); color: var(--wbc-dim); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-agentsel-check { flex: none; width: 14px; display: grid; place-items: center; color: var(--wbc-accent); opacity: 0; }
  .wbc-agentsel-item.on .wbc-agentsel-check { opacity: 1; }
  .wbc-agentsel-check svg { width: 14px; height: 14px; }
`;

const CHEV = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>';
const CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';

const nameOf = (a) => (a && typeof a === 'object') ? a.name : a;
const labelOf = (a) => (a && typeof a === 'object') ? (a.label || a.name) : a;
function themeOf(a) {
  const W = (typeof window !== 'undefined') ? window.WB : null;
  return (W && W.AGENT_THEME && W.AGENT_THEME[nameOf(a)]) || { color: 'var(--wbc-dim)', bg: 'var(--wbc-line)', icon: '' };
}

registerComposerButton((ctx) => {
  const agents = ctx.agents || [];
  if (agents.length === 0) return null;
  injectStyle('agent-selector', STYLE);

  const root = el('div', { class: 'wbc-agentsel' });
  const icd = el('span', { class: 'wbc-agentsel-ic' });
  const lbl = el('span', { class: 'wbc-agentsel-lbl' });
  const btn = el('button', {
    class: 'wbc-agentsel-btn', type: 'button', title: 'Select agent',
    onClick: (e) => { e.stopPropagation(); if (ctx.agentLocked()) return; toggle(); },
  }, [icd, lbl, el('span', { class: 'wbc-agentsel-chev', html: CHEV })]);
  const menu = el('div', { class: 'wbc-agentsel-menu' });
  root.append(btn, menu);

  function current() {
    const cur = nameOf(ctx.agent());
    return agents.find(a => nameOf(a) === cur) || agents[0];
  }
  function syncLabel() {
    const a = current();
    const th = themeOf(a);
    icd.style.background = th.bg; icd.style.color = th.color; icd.innerHTML = th.icon || '';
    lbl.textContent = labelOf(a);
    root.classList.toggle('locked', !!ctx.agentLocked());
    btn.title = ctx.agentLocked() ? (labelOf(a) + ' — locked for this session') : 'Select agent';
  }

  function buildMenu() {
    menu.innerHTML = '';
    const cur = nameOf(ctx.agent());
    agents.forEach(a => {
      const nm = nameOf(a);
      const th = themeOf(a);
      const ic = el('span', { class: 'wbc-agentsel-ic', html: th.icon || '' });
      ic.style.background = th.bg; ic.style.color = th.color;
      const item = el('button', {
        class: 'wbc-agentsel-item' + (nm === cur ? ' on' : ''), type: 'button',
        onClick: (e) => { e.stopPropagation(); ctx.setAgent(nm); syncLabel(); close(); },
      }, [
        ic,
        el('div', { class: 'wbc-agentsel-itemtt' }, [
          el('div', { class: 'wbc-agentsel-itemlbl' }, labelOf(a)),
          (a && a.blurb) ? el('div', { class: 'wbc-agentsel-itemsub' }, a.blurb) : null,
        ].filter(Boolean)),
        el('span', { class: 'wbc-agentsel-check', html: CHECK }),
      ]);
      menu.append(item);
    });
  }

  let onDoc = null;
  function open() { buildMenu(); root.classList.add('open'); onDoc = (e) => { if (!root.contains(e.target)) close(); }; document.addEventListener('click', onDoc); }
  function close() { root.classList.remove('open'); if (onDoc) { document.removeEventListener('click', onDoc); onDoc = null; } }
  function toggle() { root.classList.contains('open') ? close() : open(); }

  // Re-sync the lock state + label whenever the conversation changes (first message pins the agent).
  if (ctx.onChange) ctx.onChange(() => syncLabel());
  syncLabel();
  return root;
});
