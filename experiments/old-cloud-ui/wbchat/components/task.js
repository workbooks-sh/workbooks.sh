// wbchat/components/task — Tier-2 "Task" checklist part.
// Shape: { type:'task', title?, items:[{ label, status }] }
//   status ∈ pending | active | done | error
// Renders a collapsible (core collapsible) titled `title || 'Task'` with a progress aside
// (done/total); body is a checklist — each item a row with a status glyph + label.
// Reference: ai-elements Task. Self-contained: own CSS themed against the --wbc-* contract.

import { registerPart, el, collapsible, injectStyle } from '../core.js';

injectStyle('task', `
  .wbc-task-list { display: flex; flex-direction: column; gap: 2px; }
  .wbc-task-row { display: flex; align-items: flex-start; gap: 9px; padding: 5px 2px;
    font: 500 13px var(--wbc-font); line-height: 1.5; color: var(--wbc-ink); }
  .wbc-task-glyph { flex: none; width: 16px; height: 16px; margin-top: 1px; display: grid; place-items: center; }
  .wbc-task-glyph svg { width: 16px; height: 16px; }
  .wbc-task-lbl { min-width: 0; word-break: break-word; }

  .wbc-task-row.pending .wbc-task-glyph { color: var(--wbc-dim); }
  .wbc-task-row.pending .wbc-task-lbl   { color: var(--wbc-dim); }
  .wbc-task-row.active  .wbc-task-glyph { color: var(--wbc-accent); }
  .wbc-task-row.active  .wbc-task-lbl   { color: var(--wbc-ink); }
  .wbc-task-row.done    .wbc-task-glyph { color: color-mix(in srgb, #4ade80 80%, var(--wbc-ink)); }
  .wbc-task-row.done    .wbc-task-lbl   { color: var(--wbc-dim); }
  .wbc-task-row.error   .wbc-task-glyph { color: color-mix(in srgb, #f87171 82%, var(--wbc-ink)); }
  .wbc-task-row.error   .wbc-task-lbl   { color: color-mix(in srgb, #f87171 82%, var(--wbc-ink)); }

  .wbc-task-spin { transform-origin: center; animation: wbc-task-spin 0.9s linear infinite; }
  @keyframes wbc-task-spin { to { transform: rotate(360deg); } }
`);

const GLYPH = {
  done: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>',
  error: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"/></svg>',
  active: '<svg class="wbc-task-spin" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M21 12a9 9 0 1 1-6.22-8.56" opacity=".9"/></svg>',
  pending: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-dasharray="2 3"><circle cx="12" cy="12" r="9"/></svg>',
};

function row(item) {
  const status = GLYPH[item.status] ? item.status : 'pending';
  return el('div', { class: 'wbc-task-row ' + status }, [
    el('span', { class: 'wbc-task-glyph', html: GLYPH[status] }),
    el('span', { class: 'wbc-task-lbl' }, item.label || ''),
  ]);
}

registerPart('task', (part) => {
  const items = Array.isArray(part.items) ? part.items : [];
  const total = items.length;
  const done = items.filter(i => i && i.status === 'done').length;
  const hasError = items.some(i => i && i.status === 'error');
  const active = items.some(i => i && i.status === 'active');

  const aside = total ? `${done}/${total}` : undefined;
  const { root, content } = collapsible({
    title: part.title || 'Task',
    open: active || hasError || (total > 0 && done < total),
    aside,
  });
  root.classList.add('wbc-task');

  const list = el('div', { class: 'wbc-task-list' });
  if (total) items.forEach(i => list.append(row(i)));
  else list.append(el('div', { class: 'wbc-task-row pending' }, [el('span', { class: 'wbc-task-lbl' }, 'No items.')]));
  content.append(list);
  return root;
});
