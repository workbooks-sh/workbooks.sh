// wbchat/components/sources — a 'sources' message part. Collapsible citations list (ai-elements Sources
// parity): a disclosure titled "Sources" with the source count as the aside; the body is a list of
// rows, each an external anchor showing the title (or hostname) + a dim hostname/snippet line.
// Self-contained: imports the core API, ships its own --wbc-themed CSS via injectStyle.
import { registerPart, el, icon, copy, collapsible, injectStyle } from '../core.js';

const STYLE = `
  .wbc-sources { display: flex; flex-direction: column; gap: 2px; }
  .wbc-source { display: flex; gap: 10px; align-items: flex-start; text-decoration: none; color: var(--wbc-ink);
    padding: 8px 10px; border-radius: var(--wbc-radius-sm); transition: background .12s; }
  .wbc-source:hover { background: var(--wbc-code-bg); }
  .wbc-source-num { flex: none; width: 18px; height: 18px; margin-top: 1px; border-radius: 5px;
    display: grid; place-items: center; font: 600 10.5px var(--wbc-mono);
    background: color-mix(in srgb, var(--wbc-accent) 22%, transparent); color: var(--wbc-ink); }
  .wbc-source-body { min-width: 0; flex: 1; display: flex; flex-direction: column; gap: 2px; }
  .wbc-source-title { font: 600 13px var(--wbc-font); line-height: 1.4;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-source:hover .wbc-source-title { color: var(--wbc-accent); }
  .wbc-source-meta { font: 500 11.5px var(--wbc-font); color: var(--wbc-dim); line-height: 1.45;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .wbc-source-host { font: 500 11px var(--wbc-mono); color: var(--wbc-dim);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wbc-source-ext { flex: none; color: var(--wbc-dim); opacity: 0; transition: opacity .12s; margin-top: 2px; }
  .wbc-source:hover .wbc-source-ext { opacity: 1; }
  .wbc-source-ext svg { width: 13px; height: 13px; }`;

const EXT = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>';

function hostname(url) {
  try { return new URL(url).hostname.replace(/^www\./, ''); } catch (_) { return (url || '').replace(/^https?:\/\//, '').split('/')[0] || url || ''; }
}

registerPart('sources', (part) => {
  injectStyle('sources', STYLE);
  const sources = Array.isArray(part.sources) ? part.sources : [];
  const { root, content } = collapsible({ title: 'Sources', aside: String(sources.length) });

  const list = el('div', { class: 'wbc-sources' });
  sources.forEach((s, i) => {
    const host = hostname(s.url);
    const title = (s.title && String(s.title).trim()) || host || s.url || 'Untitled source';
    const metaText = (s.snippet && String(s.snippet).trim()) || host;
    const body = [el('div', { class: 'wbc-source-title', title }, title)];
    if (metaText) body.push(el('div', { class: s.snippet ? 'wbc-source-meta' : 'wbc-source-host' }, metaText));
    list.append(el('a', {
      class: 'wbc-source', href: s.url || '#', target: '_blank', rel: 'noopener noreferrer',
    }, [
      el('span', { class: 'wbc-source-num' }, String(i + 1)),
      el('div', { class: 'wbc-source-body' }, body),
      el('span', { class: 'wbc-source-ext', html: EXT }),
    ]));
  });

  content.append(list);
  return root;
});
