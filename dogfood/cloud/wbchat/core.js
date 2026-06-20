// wbchat/core — the SINGULAR API surface. Framework-agnostic vanilla JS: createChat(el, options)
// returns a controller. Everything else (components) plugs in via the part-renderer registry, so the
// core is the one contract that prevents drift. No framework lock-in; consume from any framework by
// calling createChat() inside a mount hook.
//
// THE CONTRACT (what fan-out components build against):
//   registerPart(type, (part, ctx) => Node)   — render a message part of `type`. ctx = { role, md,
//                                                el, icon, copy, controller }. Components are
//                                                self-contained modules that import this and register.
//   message model: { id, role:'user'|'assistant', parts:[{type, ...}], meta }
//   controller: addMessage, setMessages, clear, submit, stop, on(evt,fn), destroy, state
//   adapter seam: options.send(text, { delta(chunk), signal }) -> Promise<string|void>
//
// Ships Tier-1 inline (text+markdown, code, conversation, composer, loader, suggestions, actions).
// Tier-2/3 parts (reasoning, tool, sources, attachments, …) are added as separate modules that call
// registerPart — no edits to this file, no conflicts.

const parts = {};
export function registerPart(type, fn) { parts[type] = fn; }
export function getParts() { return parts; }

// ── tiny DOM + helpers (shared primitives) ──────────────────────────────────────────────────────
export function el(tag, attrs, kids) {
  const n = document.createElement(tag);
  if (attrs) for (const k in attrs) {
    if (k === 'class') n.className = attrs[k];
    else if (k === 'html') n.innerHTML = attrs[k];
    else if (k.slice(0, 2) === 'on' && typeof attrs[k] === 'function') n.addEventListener(k.slice(2).toLowerCase(), attrs[k]);
    else if (attrs[k] != null) n.setAttribute(k, attrs[k]);
  }
  if (kids != null) (Array.isArray(kids) ? kids : [kids]).forEach(c => c != null && n.append(c.nodeType ? c : document.createTextNode(c)));
  return n;
}
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
export function copy(text) { try { navigator.clipboard.writeText(text); } catch (_) {} }
export const ICON = {
  send: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13M22 2l-7 20-4-9-9-4 20-7z"/></svg>',
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>',
  refresh: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 0 1 15-6.7L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15 6.7L3 16"/><path d="M3 21v-5h5"/></svg>',
  down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M19 12l-7 7-7-7"/></svg>',
};
export function icon(name) { return el('span', { html: ICON[name] || '', class: 'wbc-ico' }); }

// Inject a component's own CSS once (keyed by id) — so each component module is SELF-CONTAINED (JS +
// its styles) and parallel components never edit a shared stylesheet. Convention for all add-on parts.
export function injectStyle(id, css) {
  if (document.getElementById('wbc-style-' + id)) return;
  const s = document.createElement('style'); s.id = 'wbc-style-' + id; s.textContent = css; document.head.appendChild(s);
}

// Shared collapsible primitive — reused by reasoning / tool / sources / chain-of-thought components.
// Returns { root, content, setOpen, isOpen }. Header shows `title` (+ optional right-side `aside`).
export function collapsible({ title, open = false, aside } = {}) {
  injectStyle('collapsible', `
    .wbc-collapse { border: 1px solid var(--wbc-line); border-radius: var(--wbc-radius-sm); overflow: hidden; margin: 0 0 8px; }
    .wbc-collapse-hd { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left; cursor: pointer;
      border: none; background: var(--wbc-code-bg); color: var(--wbc-ink); font: 600 12.5px var(--wbc-font); padding: 9px 12px; }
    .wbc-collapse-hd:hover { background: var(--wbc-line); }
    .wbc-collapse-chev { margin-left: auto; transition: transform .15s; color: var(--wbc-dim); display: grid; place-items: center; }
    .wbc-collapse.open .wbc-collapse-chev { transform: rotate(90deg); }
    .wbc-collapse-aside { color: var(--wbc-dim); font: 500 11.5px var(--wbc-mono); margin-left: auto; }
    .wbc-collapse-body { display: none; padding: 12px; border-top: 1px solid var(--wbc-line); }
    .wbc-collapse.open .wbc-collapse-body { display: block; }
    .wbc-collapse.open .wbc-collapse-aside { margin-left: 0; }`);
  const chev = el('span', { class: 'wbc-collapse-chev', html: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 6l6 6-6 6"/></svg>' });
  const asideEl = aside != null ? el('span', { class: 'wbc-collapse-aside' }, aside) : null;
  const content = el('div', { class: 'wbc-collapse-body' });
  const root = el('div', { class: 'wbc-collapse' + (open ? ' open' : '') });
  const hd = el('button', { class: 'wbc-collapse-hd', onClick: () => setOpen(!root.classList.contains('open')) },
    [el('span', null, title), asideEl, chev].filter(Boolean));
  root.append(hd, content);
  function setOpen(v) { root.classList.toggle('open', !!v); }
  return { root, content, setOpen, isOpen: () => root.classList.contains('open') };
}

// markdown — loaded lazily; escaped fallback so the core never hard-depends on the network.
let _md = (t) => '<p>' + esc(t).replace(/\n/g, '<br>') + '</p>';
async function loadMarkdown() {
  try { const m = await import('https://esm.sh/marked@13'); if (m && m.marked) _md = (t) => m.marked.parse(String(t || '')); } catch (_) {}
}
export function md(t) { return _md(t); }

// ── default Tier-1 part renderers ────────────────────────────────────────────────────────────────
registerPart('text', (part, ctx) => {
  if (ctx.role === 'user') return el('div', { class: 'wbc-bubble' }, part.text);
  return el('div', { class: 'wbc-bubble' }, [el('div', { class: 'wbc-md', html: ctx.md(part.text) })]);
});
registerPart('code', (part) => {
  const wrap = el('div', { class: 'wbc-code' });
  const copyBtn = el('button', { class: 'wbc-code-copy', onClick: () => { copy(part.code); copyBtn.textContent = 'copied'; setTimeout(() => copyBtn.textContent = 'copy', 1200); } }, 'copy');
  wrap.append(el('div', { class: 'wbc-code-hd' }, [el('span', null, part.lang || 'code'), copyBtn]));
  wrap.append(el('pre', null, [el('code', null, part.code)]));
  return wrap;
});

// ── createChat ────────────────────────────────────────────────────────────────────────────────
let _seq = 0;
export function createChat(container, options = {}) {
  const opts = Object.assign({ placeholder: 'Message the agent…', suggestions: [], greeting: null, scheme: null }, options);
  const listeners = {};
  let messages = [];
  let status = 'idle'; // idle | pending | streaming
  let abort = null;

  const root = el('div', { class: 'wb-chat' });
  if (opts.scheme) root.setAttribute('data-color-scheme', opts.scheme);
  const convo = el('div', { class: 'wbc-convo' });
  const convoInner = el('div', { class: 'wbc-convo-inner' });
  convo.append(convoInner);
  const scrollBtn = el('button', { class: 'wbc-scrollbtn', html: ICON.down, onClick: () => scrollToEnd(true) });
  const composer = buildComposer();
  root.append(convo, scrollBtn, composer);
  container.innerHTML = '';
  container.append(root);
  loadMarkdown().then(render);

  function emit(evt, payload) { (listeners[evt] || []).forEach(f => { try { f(payload); } catch (_) {} }); }
  function atBottom() { return convo.scrollHeight - convo.scrollTop - convo.clientHeight < 60; }
  function scrollToEnd(force) { if (force || atBottom()) convo.scrollTop = convo.scrollHeight; }
  convo.addEventListener('scroll', () => scrollBtn.classList.toggle('on', !atBottom()));

  const ctxFor = (role) => ({ role, md, el, icon, copy, controller });

  function renderMessage(m) {
    const row = el('div', { class: 'wbc-msg ' + m.role });
    (m.parts || []).forEach(p => { const r = (parts[p.type] || parts.text); row.append(r(p, ctxFor(m.role))); });
    if (m.role === 'assistant' && status === 'idle') row.append(messageActions(m));
    return row;
  }
  function messageActions(m) {
    const text = (m.parts || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
    const bar = el('div', { class: 'wbc-actions' });
    bar.append(el('button', { class: 'wbc-act', title: 'Copy', html: ICON.copy, onClick: () => copy(text) }));
    bar.append(el('button', { class: 'wbc-act', title: 'Regenerate', html: ICON.refresh, onClick: () => regenerate(m) }));
    return bar;
  }

  function render() {
    convoInner.innerHTML = '';
    if (messages.length === 0) { convoInner.append(emptyState()); return; }
    messages.forEach(m => convoInner.append(renderMessage(m)));
    if (status === 'pending') convoInner.append(el('div', { class: 'wbc-msg assistant' }, [el('div', { class: 'wbc-bubble' }, [typing()])]));
    scrollToEnd();
  }
  function typing() { return el('div', { class: 'wbc-typing' }, [el('i'), el('i'), el('i')]); }
  function emptyState() {
    const wrap = el('div', { class: 'wbc-empty' });
    if (opts.greeting) wrap.append(el('h3', null, opts.greeting.title || 'Start a chat'), el('p', null, opts.greeting.text || ''));
    if (opts.suggestions && opts.suggestions.length) {
      const s = el('div', { class: 'wbc-suggest' });
      opts.suggestions.forEach(t => s.append(el('button', { class: 'wbc-chip', onClick: () => submit(t) }, t)));
      wrap.append(s);
    }
    return wrap;
  }

  // ── composer ──
  function buildComposer() {
    const wrap = el('div', { class: 'wbc-composer' });
    const inner = el('div', { class: 'wbc-composer-inner' });
    const ta = el('textarea', { class: 'wbc-textarea', rows: '1', placeholder: opts.placeholder });
    const send = el('button', { class: 'wbc-send', html: ICON.send, title: 'Send' });
    const grow = () => { ta.style.height = 'auto'; ta.style.height = Math.min(ta.scrollHeight, 200) + 'px'; };
    ta.addEventListener('input', grow);
    ta.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); fire(); } });
    send.addEventListener('click', fire);
    function fire() { const v = ta.value.trim(); if (!v || status !== 'idle') return; ta.value = ''; grow(); submit(v); }
    inner.append(ta, send);
    wrap.append(inner);
    wrap._ta = ta; wrap._send = send;
    return wrap;
  }
  function setBusy(b) { composer._send.disabled = b; }

  // ── flow ──
  async function submit(text) {
    if (status !== 'idle') return;
    const userMsg = { id: ++_seq, role: 'user', parts: [{ type: 'text', text }] };
    messages.push(userMsg);
    emit('send', { text }); emit('change', { messages });
    status = 'pending'; setBusy(true); render();

    const assistant = { id: ++_seq, role: 'assistant', parts: [{ type: 'text', text: '' }] };
    let started = false;
    abort = new AbortController();
    const onDelta = (chunk) => {
      if (!started) { started = true; status = 'streaming'; messages.push(assistant); }
      assistant.parts[0].text += chunk; render();
    };
    try {
      const ret = await (opts.send ? opts.send(text, { delta: onDelta, signal: abort.signal }) : Promise.resolve('(no adapter wired)'));
      if (!started && typeof ret === 'string') { assistant.parts[0].text = ret; messages.push(assistant); }
      else if (started && typeof ret === 'string' && ret) assistant.parts[0].text = ret;
    } catch (e) {
      if (!started) messages.push(assistant);
      assistant.parts[0].text = assistant.parts[0].text || 'The agent run failed — try again.';
    }
    status = 'idle'; abort = null; setBusy(false); render();
    emit('response', { message: assistant }); emit('change', { messages });
  }
  function regenerate(m) {
    const idx = messages.indexOf(m);
    if (idx < 1) return;
    const prevUser = messages[idx - 1];
    messages = messages.slice(0, idx);
    render();
    if (prevUser && prevUser.role === 'user') submit(prevUser.parts.map(p => p.text).join('\n'));
  }

  // ── controller (public API) ──
  const controller = {
    get messages() { return messages; },
    get status() { return status; },
    addMessage(m) { messages.push(normalize(m)); render(); return controller; },
    setMessages(list) { messages = (list || []).map(normalize); render(); return controller; },
    clear() { messages = []; render(); return controller; },
    submit(text) { submit(text); return controller; },
    stop() { if (abort) abort.abort(); status = 'idle'; setBusy(false); render(); return controller; },
    focus() { composer._ta.focus(); return controller; },
    on(evt, fn) { (listeners[evt] = listeners[evt] || []).push(fn); return controller; },
    destroy() { container.innerHTML = ''; },
    el, render,
  };
  function normalize(m) {
    if (m.parts) return { id: m.id || ++_seq, role: m.role, parts: m.parts, meta: m.meta };
    return { id: m.id || ++_seq, role: m.role, parts: [{ type: 'text', text: m.text || '' }], meta: m.meta };
  }
  return controller;
}
