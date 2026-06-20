// wbchat/components/feedback — assistant-message thumbs-up / thumbs-down rating.
// Appended to the action bar via registerAction. Only renders for assistant messages.
// State is local + persisted on the message object: message.meta.feedback ∈ 'up' | 'down' | undefined.
// Clicking toggles (click the active one to clear); up XOR down — selecting one clears the other.
// Active button colored with var(--wbc-accent). No backend; reference: assistant-ui feedback.

import { registerAction, el, injectStyle } from '../core.js';

injectStyle('feedback', `
  .wbc-fb { border: none; background: none; color: var(--wbc-dim); cursor: pointer; padding: 4px;
    border-radius: 7px; display: grid; place-items: center; }
  .wbc-fb:hover { background: var(--wbc-line); color: var(--wbc-ink); }
  .wbc-fb.active { color: var(--wbc-accent); }
  .wbc-fb svg { width: 15px; height: 15px; }
`);

const UP = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7 10v12"/><path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/></svg>';
const DOWN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M17 14V2"/><path d="M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z"/></svg>';

registerAction((message, ctx) => {
  if (message.role !== 'assistant') return null;
  const meta = message.meta = message.meta || {};

  const up = el('button', { class: 'wbc-fb', title: 'Good response', html: UP });
  const down = el('button', { class: 'wbc-fb', title: 'Bad response', html: DOWN });

  function sync() {
    up.classList.toggle('active', meta.feedback === 'up');
    down.classList.toggle('active', meta.feedback === 'down');
  }
  function set(v) { meta.feedback = meta.feedback === v ? undefined : v; sync(); }

  up.addEventListener('click', () => set('up'));
  down.addEventListener('click', () => set('down'));
  sync();

  return el('span', { class: 'wbc-fb-grp' }, [up, down]);
});
