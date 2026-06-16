// docs/prose.js — the shared themed-prose CSS for the docs domain.
//
// A Lit `css` CSSResult (composes into `static styles` via `${PROSE_CSS}`).
// Token-only (every value var(--wb-*)). Imported by work-doc + work-doc-cell so the
// rendered document and its live cells read as one typeset surface. Mirrors the
// visual contract of the desktop org-renderer (desktop/src/lib/org-renderer/
// org.css) but expressed purely from the workponents token set.

import { css } from "../../core/element.js";

export const PROSE_CSS = css`
  .prose {
    font-family: var(--wb-font);
    font-size: var(--wb-text);
    line-height: 1.7;
    color: var(--wb-fg);
  }
  .prose > :first-child { margin-top: 0; }
  .prose > :last-child { margin-bottom: 0; }

  .prose h1, .prose h2, .prose h3, .prose h4, .prose h5, .prose h6 {
    font-family: var(--wb-font-display, var(--wb-font));
    font-weight: 600;
    line-height: 1.25;
    letter-spacing: -0.01em;
    color: var(--wb-fg);
    scroll-margin-top: var(--wb-space-5);
    display: flex; align-items: center; flex-wrap: wrap; gap: var(--wb-space-2);
  }
  .prose h1 { font-size: 1.7em; margin: 1.6em 0 0.6em; padding-bottom: var(--wb-space-2); border-bottom: 1px solid var(--wb-border); }
  .prose h2 { font-size: 1.35em; margin: 1.5em 0 0.5em; }
  .prose h3 { font-size: 1.12em; margin: 1.3em 0 0.4em; }
  .prose h4 { font-size: 1em; margin: 1.1em 0 0.35em; color: var(--wb-fg-muted); }
  .prose p { margin: 0.85em 0; }

  .prose a {
    color: var(--wb-brand);
    text-decoration: none;
    border-bottom: 1px solid color-mix(in srgb, var(--wb-brand) 45%, transparent);
  }
  .prose a:hover { border-bottom-color: var(--wb-brand); }

  .prose ul, .prose ol { margin: 0.7em 0; padding-left: 1.4em; }
  .prose li { margin: 0.25em 0; }
  .prose li.doc-task { list-style: none; margin-left: -1.4em; display: flex; align-items: baseline; gap: var(--wb-space-2); }
  .prose li.doc-task input { accent-color: var(--wb-brand); }

  .prose code {
    font-family: var(--wb-font-mono);
    font-size: 0.86em;
    padding: 0.1em 0.4em;
    border-radius: var(--wb-radius-sm);
    background: var(--wb-surface-soft);
    color: var(--wb-fg);
  }
  .prose pre {
    margin: 1em 0;
    padding: var(--wb-space-4);
    border-radius: var(--wb-radius);
    background: var(--wb-surface-soft);
    border: 1px solid var(--wb-border);
    overflow-x: auto;
  }
  .prose pre code { background: none; padding: 0; font-size: var(--wb-text-sm); line-height: 1.6; }

  .prose blockquote {
    margin: 1em 0;
    padding: var(--wb-space-2) var(--wb-space-4);
    border-left: 3px solid var(--wb-brand);
    background: var(--wb-brand-soft);
    border-radius: 0 var(--wb-radius-sm) var(--wb-radius-sm) 0;
    color: var(--wb-fg-muted);
  }

  .prose hr { border: none; border-top: 1px solid var(--wb-border); margin: 1.8em 0; }

  .prose table {
    width: 100%;
    border-collapse: collapse;
    margin: 1em 0;
    font-size: var(--wb-text-sm);
  }
  .prose th, .prose td {
    text-align: left;
    padding: var(--wb-space-2) var(--wb-space-3);
    border-bottom: 1px solid var(--wb-border);
  }
  .prose th { font-weight: 600; color: var(--wb-fg-muted); border-bottom-color: var(--wb-border-strong); }
  .prose tbody tr:hover { background: var(--wb-surface-soft); }

  /* org TODO pills + tag chips on headings */
  .doc-state {
    font-family: var(--wb-font-mono);
    font-size: 0.62em; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase;
    padding: 0.2em 0.55em; border-radius: var(--wb-radius-pill);
    background: var(--wb-surface-soft); color: var(--wb-fg-muted);
    border: 1px solid var(--wb-border);
  }
  .doc-state-done { background: var(--wb-brand-soft); color: var(--wb-ok); border-color: transparent; }
  .doc-state-todo, .doc-state-next { background: var(--wb-brand-soft); color: var(--wb-brand); border-color: transparent; }
  .doc-state-wait, .doc-state-blocked { color: var(--wb-warn); }
  .doc-state-cancelled { color: var(--wb-err); text-decoration: line-through; }
  .doc-tags { display: inline-flex; gap: var(--wb-space-1); }
  .doc-tag {
    font-family: var(--wb-font-mono); font-size: 0.6em; font-weight: 600;
    padding: 0.15em 0.5em; border-radius: var(--wb-radius-pill);
    background: var(--wb-surface-soft); color: var(--wb-fg-subtle);
  }
`;
