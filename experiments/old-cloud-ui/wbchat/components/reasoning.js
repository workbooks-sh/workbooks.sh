// wbchat/components/reasoning — Tier-2 "Reasoning" part.
// Shape: { type:'reasoning', text, streaming?:bool, duration?:number }
// Collapsible "Reasoning" disclosure (ai-elements / assistant-ui parity): header titled "Reasoning"
// with a duration aside ("thought for Ns") and, while streaming, a subtle pulsing dot. Body renders
// ctx.md(part.text) in a muted .wbc-md block. Streaming defaults OPEN; settled defaults CLOSED.
import { registerPart, el, collapsible, injectStyle } from '../core.js';

injectStyle('reasoning', `
  .wbc-reasoning .wbc-collapse-hd { font-weight: 600; }
  .wbc-reasoning-title { display: inline-flex; align-items: center; gap: 7px; }
  .wbc-reasoning-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--wbc-accent);
    box-shadow: 0 0 0 0 var(--wbc-focus); animation: wbc-reasoning-pulse 1.4s ease-out infinite; }
  @keyframes wbc-reasoning-pulse {
    0%   { box-shadow: 0 0 0 0 var(--wbc-focus); opacity: 1; }
    70%  { box-shadow: 0 0 0 5px transparent; opacity: .55; }
    100% { box-shadow: 0 0 0 0 transparent; opacity: 1; }
  }
  .wbc-reasoning-body { color: var(--wbc-dim); font: 400 13px var(--wbc-font); line-height: 1.6; }
  .wbc-reasoning-body p { margin: 0 0 8px; }
  .wbc-reasoning-body > :last-child { margin-bottom: 0; }
  .wbc-reasoning-body code { background: var(--wbc-code-bg); border-radius: 5px; padding: .1em .35em; font: 12px var(--wbc-mono); }
`);

function durationLabel(d) {
  if (d == null) return undefined;
  const s = Number(d);
  if (!isFinite(s) || s <= 0) return undefined;
  const txt = s >= 60 ? `${Math.round(s / 60)}m` : (s % 1 === 0 ? `${s}s` : `${s.toFixed(1)}s`);
  return `thought for ${txt}`;
}

registerPart('reasoning', (part, ctx) => {
  const streaming = !!part.streaming;
  const title = el('span', { class: 'wbc-reasoning-title' }, [
    'Reasoning',
    streaming ? el('span', { class: 'wbc-reasoning-dot' }) : null,
  ].filter(Boolean));

  const c = collapsible({ title, open: streaming, aside: durationLabel(part.duration) });
  c.root.classList.add('wbc-reasoning');
  c.content.append(el('div', { class: 'wbc-md wbc-reasoning-body', html: ctx.md(part.text || '') }));
  return c.root;
});
