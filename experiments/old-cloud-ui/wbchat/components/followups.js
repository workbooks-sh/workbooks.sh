// wbchat/components/followups — Tier-2 "suggestions" part (post-response follow-up prompts).
// Part shape: { type:'suggestions', suggestions:[string] }
// Renders a row of clickable pill chips; clicking a chip submits its text via ctx.controller.submit.
// Reference: ai-elements Suggestion. Self-contained: own CSS themed entirely against the --wbc-* contract.
import { registerPart, el, injectStyle } from '../core.js';

injectStyle('followups', `
  /* Suggested follow-up prompts: subtle by default (rendered after the action bar), full on hover. */
  .wbc-followups { display: flex; flex-wrap: wrap; gap: 7px; margin: 10px 0 2px; opacity: .6; transition: opacity .15s; }
  .wbc-followups:hover { opacity: 1; }
  .wbc-followup { border: 1px solid var(--wbc-line); background: transparent; color: var(--wbc-dim);
    border-radius: 999px; padding: 5px 12px; font: 500 12.5px var(--wbc-font); cursor: pointer;
    text-align: left; line-height: 1.35; transition: border-color .12s, background .12s, color .12s; }
  .wbc-followup:hover { border-color: var(--wbc-stroke); color: var(--wbc-ink); background: color-mix(in srgb, var(--wbc-accent) 10%, var(--wbc-panel)); }
  .wbc-followup:focus-visible { outline: none; border-color: var(--wbc-stroke); box-shadow: 0 0 0 3px var(--wbc-focus); }
`);

registerPart('suggestions', (part, ctx) => {
  const items = Array.isArray(part.suggestions) ? part.suggestions.filter(s => s != null && String(s).trim() !== '') : [];
  const row = el('div', { class: 'wbc-followups' });
  items.forEach(text => {
    const t = String(text);
    row.append(el('button', { class: 'wbc-followup', type: 'button', onClick: () => ctx.controller.submit(t) }, t));
  });
  return row;
});
