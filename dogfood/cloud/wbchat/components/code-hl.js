// wbchat/components/code-hl — RE-registers the 'code' part with syntax highlighting (ai-elements
// CodeBlock parity). Keeps the core's structure (.wbc-code > .wbc-code-hd[lang + copy] + <pre><code>)
// and layers highlight.js on top, loaded LAZILY from esm.sh. If hljs fails to load (offline), it
// falls back to plain escaped code — it NEVER throws. The hljs theme is remapped onto --wbc-* tokens
// so it sits naturally on var(--wbc-code-bg).

import { registerPart, el, copy, injectStyle } from '../core.js';

const STYLE_ID = 'code-hl';

// highlight.js theme, remapped onto our --wbc-* contract. Tokens reference the theme vars so a reskin
// of --wbc-accent / --wbc-ink / --wbc-dim flows straight through to the syntax colors.
const CSS = `
.wbc-code .hljs { display: block; background: transparent; color: var(--wbc-ink); }
.wbc-code pre code.hljs { padding: 0; background: none; }

/* comments / quotes — dimmed */
.wbc-code .hljs-comment, .wbc-code .hljs-quote { color: var(--wbc-dim); font-style: italic; }

/* keywords / control flow — accent */
.wbc-code .hljs-keyword, .wbc-code .hljs-selector-tag, .wbc-code .hljs-built_in,
.wbc-code .hljs-name, .wbc-code .hljs-tag {
  color: var(--wbc-accent); font-weight: 600;
}

/* strings / regex — soft warm mix */
.wbc-code .hljs-string, .wbc-code .hljs-regexp, .wbc-code .hljs-meta-string,
.wbc-code .hljs-symbol, .wbc-code .hljs-bullet, .wbc-code .hljs-addition {
  color: color-mix(in srgb, var(--wbc-accent) 55%, var(--wbc-ink));
}

/* numbers / literals / constants */
.wbc-code .hljs-number, .wbc-code .hljs-literal, .wbc-code .hljs-type,
.wbc-code .hljs-params, .wbc-code .hljs-template-variable {
  color: color-mix(in srgb, var(--wbc-accent) 80%, var(--wbc-dim));
}

/* identifiers — titles, attrs, vars */
.wbc-code .hljs-title, .wbc-code .hljs-class .hljs-title, .wbc-code .hljs-function .hljs-title {
  color: var(--wbc-ink); font-weight: 600;
}
.wbc-code .hljs-attr, .wbc-code .hljs-attribute, .wbc-code .hljs-variable,
.wbc-code .hljs-property, .wbc-code .hljs-selector-id, .wbc-code .hljs-selector-class {
  color: color-mix(in srgb, var(--wbc-ink) 80%, var(--wbc-accent));
}

/* meta / punctuation / deletion */
.wbc-code .hljs-meta, .wbc-code .hljs-comment .hljs-doctag { color: var(--wbc-dim); }
.wbc-code .hljs-deletion { color: color-mix(in srgb, var(--wbc-ink) 50%, transparent); }
.wbc-code .hljs-emphasis { font-style: italic; }
.wbc-code .hljs-strong { font-weight: 700; }
`;

// Lazy, cached, fail-soft load of highlight.js (full common build).
let _hljsPromise = null;
function loadHljs() {
  if (_hljsPromise) return _hljsPromise;
  _hljsPromise = import('https://esm.sh/highlight.js@11')
    .then((m) => (m && (m.default || m)) || null)
    .catch(() => null);
  return _hljsPromise;
}

registerPart('code', (part) => {
  injectStyle(STYLE_ID, CSS);

  const lang = part.lang || 'code';
  const wrap = el('div', { class: 'wbc-code' });

  const copyBtn = el('button', {
    class: 'wbc-code-copy',
    onClick: () => {
      copy(part.code);
      copyBtn.textContent = 'copied';
      setTimeout(() => { copyBtn.textContent = 'copy'; }, 1200);
    },
  }, 'copy');

  wrap.append(el('div', { class: 'wbc-code-hd' }, [el('span', null, lang), copyBtn]));

  // Plain escaped code first — this is the fallback that always renders. el() text-nodes the code,
  // so it's escaped for us and safe.
  const codeEl = el('code', null, part.code);
  wrap.append(el('pre', null, [codeEl]));

  // Upgrade to highlighted markup once hljs is available. Never throws.
  loadHljs().then((hljs) => {
    if (!hljs || !codeEl.isConnected && !wrap.isConnected) {
      // still try; render path may be detached briefly during streaming re-render
    }
    if (!hljs) return;
    try {
      let result;
      if (part.lang && typeof hljs.getLanguage === 'function' && hljs.getLanguage(part.lang)) {
        result = hljs.highlight(String(part.code || ''), { language: part.lang, ignoreIllegals: true });
      } else if (typeof hljs.highlightAuto === 'function') {
        result = hljs.highlightAuto(String(part.code || ''));
      }
      if (result && typeof result.value === 'string') {
        codeEl.className = 'hljs';
        codeEl.innerHTML = result.value;
      }
    } catch (_) { /* keep the escaped fallback */ }
  });

  return wrap;
});
