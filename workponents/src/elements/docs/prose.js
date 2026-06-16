// docs/prose.js — the shared themed-prose CSS for the docs domain.
//
// A Lit `css` CSSResult (composes into `static styles` via `${PROSE_CSS}`).
// Token-only (every value var(--work-*)). Imported by document-view + document-cell so the
// rendered document and its live cells read as one typeset surface. Mirrors the
// visual contract of the desktop org-renderer (desktop/src/lib/org-renderer/
// org.css) but expressed purely from the workponents token set.

import { css } from "../../core/element.js";

export const PROSE_CSS = css`
  .prose {
    font-family: var(--work-font);
    font-size: var(--work-text);
    line-height: 1.7;
    color: var(--work-fg);
  }
  .prose > :first-child { margin-top: 0; }
  .prose > :last-child { margin-bottom: 0; }

  .prose h1, .prose h2, .prose h3, .prose h4, .prose h5, .prose h6 {
    font-family: var(--work-font-display, var(--work-font));
    font-weight: 600;
    line-height: 1.25;
    letter-spacing: -0.01em;
    color: var(--work-fg);
    scroll-margin-top: var(--work-space-5);
    display: flex; align-items: center; flex-wrap: wrap; gap: var(--work-space-2);
  }
  .prose h1 { font-size: 1.7em; margin: 1.6em 0 0.6em; padding-bottom: var(--work-space-2); border-bottom: 1px solid var(--work-border); }
  .prose h2 { font-size: 1.35em; margin: 1.5em 0 0.5em; }
  .prose h3 { font-size: 1.12em; margin: 1.3em 0 0.4em; }
  .prose h4 { font-size: 1em; margin: 1.1em 0 0.35em; color: var(--work-fg-muted); }
  .prose p { margin: 0.85em 0; }

  .prose a {
    color: var(--work-brand);
    text-decoration: none;
    border-bottom: 1px solid color-mix(in srgb, var(--work-brand) 45%, transparent);
  }
  .prose a:hover { border-bottom-color: var(--work-brand); }

  .prose ul, .prose ol { margin: 0.7em 0; padding-left: 1.4em; }
  .prose li { margin: 0.25em 0; }
  .prose li.doc-task { list-style: none; margin-left: -1.4em; display: flex; align-items: baseline; gap: var(--work-space-2); }
  .prose li.doc-task input { accent-color: var(--work-brand); }

  .prose code {
    font-family: var(--work-font-mono);
    font-size: 0.86em;
    padding: 0.1em 0.4em;
    border-radius: var(--work-radius-sm);
    background: var(--work-surface-soft);
    color: var(--work-fg);
  }
  .prose pre {
    margin: 1em 0;
    padding: var(--work-space-4);
    border-radius: var(--work-radius);
    background: var(--work-surface-soft);
    border: 1px solid var(--work-border);
    overflow-x: auto;
  }
  .prose pre code { background: none; padding: 0; font-size: var(--work-text-sm); line-height: 1.6; }

  .prose blockquote {
    margin: 1em 0;
    padding: var(--work-space-2) var(--work-space-4);
    border-left: 3px solid var(--work-brand);
    background: var(--work-brand-soft);
    border-radius: 0 var(--work-radius-sm) var(--work-radius-sm) 0;
    color: var(--work-fg-muted);
  }

  .prose hr { border: none; border-top: 1px solid var(--work-border); margin: 1.8em 0; }

  .prose table {
    width: 100%;
    border-collapse: collapse;
    margin: 1em 0;
    font-size: var(--work-text-sm);
  }
  .prose th, .prose td {
    text-align: left;
    padding: var(--work-space-2) var(--work-space-3);
    border-bottom: 1px solid var(--work-border);
  }
  .prose th { font-weight: 600; color: var(--work-fg-muted); border-bottom-color: var(--work-border-strong); }
  .prose tbody tr:hover { background: var(--work-surface-soft); }

  /* org TODO pills + tag chips on headings */
  .doc-state {
    font-family: var(--work-font-mono);
    font-size: 0.62em; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase;
    padding: 0.2em 0.55em; border-radius: var(--work-radius-pill);
    background: var(--work-surface-soft); color: var(--work-fg-muted);
    border: 1px solid var(--work-border);
  }
  .doc-state-done { background: var(--work-brand-soft); color: var(--work-ok); border-color: transparent; }
  .doc-state-todo, .doc-state-next { background: var(--work-brand-soft); color: var(--work-brand); border-color: transparent; }
  .doc-state-wait, .doc-state-blocked { color: var(--work-warn); }
  .doc-state-cancelled { color: var(--work-err); text-decoration: line-through; }
  .doc-tags { display: inline-flex; gap: var(--work-space-1); }
  .doc-tag {
    font-family: var(--work-font-mono); font-size: 0.6em; font-weight: 600;
    padding: 0.15em 0.5em; border-radius: var(--work-radius-pill);
    background: var(--work-surface-soft); color: var(--work-fg-subtle);
  }
`;
