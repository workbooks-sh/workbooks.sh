// wbchat/components/tool — Tier-2 tool/function-call card.
// Part shape: { type:'tool', name, state, input?, output?, error? }
//   state ∈ pending | running | complete | error
// Renders a collapsible card (core collapsible): header has a colored state badge + the tool name
// (mono); body shows pretty-printed JSON Input and the Output (or error in red). Auto-opens on
// complete/error. Reference: ai-elements Tool / assistant-ui ToolFallback. Self-contained: own CSS
// themed entirely against the --wbc-* contract.

import { registerPart, el, collapsible, injectStyle } from '../core.js';

const STYLE = `
  .wbc-tool-badge { display: inline-flex; align-items: center; gap: 6px; font: 600 11px var(--wbc-font);
    text-transform: capitalize; letter-spacing: .01em; color: var(--wbc-dim); flex: none; }
  .wbc-tool-dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; flex: none; }
  .wbc-tool-badge.pending  { color: var(--wbc-dim); }
  .wbc-tool-badge.running  { color: var(--wbc-accent); }
  .wbc-tool-badge.running .wbc-tool-dot { animation: wbc-tool-pulse 1s ease-in-out infinite; }
  .wbc-tool-badge.complete { color: color-mix(in srgb, #4ade80 80%, var(--wbc-ink)); }
  .wbc-tool-badge.error    { color: color-mix(in srgb, #f87171 82%, var(--wbc-ink)); }
  @keyframes wbc-tool-pulse { 0%,100% { opacity: 1; } 50% { opacity: .3; } }

  .wbc-tool-name { font: 600 12.5px var(--wbc-mono); color: var(--wbc-ink); }
  .wbc-tool-sec { margin: 0 0 12px; }
  .wbc-tool-sec:last-child { margin-bottom: 0; }
  .wbc-tool-lbl { font: 600 10.5px var(--wbc-font); text-transform: uppercase; letter-spacing: .06em;
    color: var(--wbc-dim); margin: 0 0 5px; }
  .wbc-tool-pre { margin: 0; background: var(--wbc-code-bg); border: 1px solid var(--wbc-line);
    border-radius: var(--wbc-radius-sm); padding: 10px 12px; overflow-x: auto;
    font: 12px var(--wbc-mono); line-height: 1.5; color: var(--wbc-ink); white-space: pre-wrap; word-break: break-word; }
  .wbc-tool-pre.error { color: color-mix(in srgb, #f87171 82%, var(--wbc-ink));
    border-color: color-mix(in srgb, #f87171 35%, var(--wbc-line)); }
  .wbc-tool-empty { font: italic 12px var(--wbc-font); color: var(--wbc-dim); }
`;

const LABEL = { pending: 'Pending', running: 'Running', complete: 'Complete', error: 'Error' };

function pretty(v) {
  if (v == null) return '';
  if (typeof v === 'string') {
    try { return JSON.stringify(JSON.parse(v), null, 2); } catch (_) { return v; }
  }
  try { return JSON.stringify(v, null, 2); } catch (_) { return String(v); }
}

function section(label, body, isError) {
  const sec = el('div', { class: 'wbc-tool-sec' });
  sec.append(el('div', { class: 'wbc-tool-lbl' }, label));
  const txt = body == null || body === '' ? '' : body;
  if (txt === '') sec.append(el('div', { class: 'wbc-tool-empty' }, '—'));
  else sec.append(el('pre', { class: 'wbc-tool-pre' + (isError ? ' error' : '') }, txt));
  return sec;
}

registerPart('tool', (part, ctx) => {
  injectStyle('tool', STYLE);
  const state = part.state || 'pending';
  const isErr = state === 'error';
  const open = state === 'complete' || state === 'error';

  const badge = el('span', { class: 'wbc-tool-badge ' + state }, [
    el('span', { class: 'wbc-tool-dot' }),
    LABEL[state] || state,
  ]);
  const title = el('span', { class: 'wbc-tool-head' }, [
    badge,
    el('span', { class: 'wbc-tool-name' }, part.name || 'tool'),
  ]);
  // Render the head row inline (badge + name) with a small gap.
  title.style.display = 'inline-flex';
  title.style.alignItems = 'center';
  title.style.gap = '10px';

  const { root, content } = collapsible({ title, open });

  if (part.input != null) content.append(section('Input', pretty(part.input)));
  if (isErr) content.append(section('Error', pretty(part.error) || 'Tool execution failed.', true));
  else if (part.output != null) content.append(section('Output', pretty(part.output)));
  else if (state === 'complete') content.append(section('Output', ''));

  if (!content.childNodes.length) content.append(el('div', { class: 'wbc-tool-empty' }, 'No details.'));

  return root;
});
