// wbchat/components/media — image + file attachment parts (ai-elements Image + attachments display).
// Two part types in one self-contained module:
//   { type:'image', url, alt? }            -> rounded, bordered lazy <img> with optional caption
//   { type:'file', name, mime?, src? }      -> compact file chip (icon + name + optional mime), links to src
import { registerPart, el, injectStyle } from '../core.js';

const STYLE = `
  .wbc-media-img { display: block; margin: 0 0 8px; max-width: 100%; }
  .wbc-media-img img { display: block; max-width: 100%; height: auto; border: 1px solid var(--wbc-line);
    border-radius: var(--wbc-radius-sm); background: var(--wbc-code-bg); }
  .wbc-media-cap { margin: 6px 2px 0; font: 500 12px var(--wbc-font); color: var(--wbc-dim); line-height: 1.45; }

  .wbc-media-file { display: inline-flex; align-items: center; gap: 10px; max-width: 100%; margin: 0 0 8px;
    padding: 9px 13px 9px 11px; border: 1px solid var(--wbc-line); border-radius: var(--wbc-radius-sm);
    background: var(--wbc-panel); color: var(--wbc-ink); text-decoration: none; font: var(--wbc-font);
    transition: border-color .12s, background .12s; box-sizing: border-box; }
  a.wbc-media-file:hover { border-color: var(--wbc-stroke); background: var(--wbc-code-bg); }
  .wbc-media-file-ic { flex: none; width: 28px; height: 28px; display: grid; place-items: center; color: var(--wbc-accent); }
  .wbc-media-file-ic svg { width: 22px; height: 22px; }
  .wbc-media-file-meta { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
  .wbc-media-file-name { font: 600 13px var(--wbc-font); color: var(--wbc-ink); white-space: nowrap;
    overflow: hidden; text-overflow: ellipsis; }
  .wbc-media-file-mime { font: 500 11px var(--wbc-mono); color: var(--wbc-dim); text-transform: uppercase; letter-spacing: .02em; }
`;

const FILE_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>';

registerPart('image', (part) => {
  injectStyle('media', STYLE);
  const fig = el('figure', { class: 'wbc-media-img' });
  fig.append(el('img', { src: part.url, alt: part.alt || '', loading: 'lazy', decoding: 'async' }));
  if (part.alt) fig.append(el('figcaption', { class: 'wbc-media-cap' }, part.alt));
  return fig;
});

registerPart('file', (part) => {
  injectStyle('media', STYLE);
  const meta = el('span', { class: 'wbc-media-file-meta' }, [
    el('span', { class: 'wbc-media-file-name', title: part.name }, part.name || 'file'),
    part.mime ? el('span', { class: 'wbc-media-file-mime' }, part.mime) : null,
  ].filter(Boolean));
  const kids = [el('span', { class: 'wbc-media-file-ic', html: FILE_SVG }), meta];
  const attrs = { class: 'wbc-media-file' };
  if (part.src) { attrs.href = part.src; attrs.target = '_blank'; attrs.rel = 'noopener noreferrer'; }
  return el(part.src ? 'a' : 'div', attrs, kids);
});
