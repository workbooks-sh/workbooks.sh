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

// message-action registry — fn(message, ctx) -> Node|null, appended to a message's action bar.
const actions = [];
export function registerAction(fn) { actions.push(fn); }
// composer add-on registry — fn(ctx) -> Node|null, inserted in the composer toolbar's bottom row.
// opts.side ('left' | 'right', default 'left') picks which group: selectors (agent/model) go left, the
// file/mic actions go right next to the send button.
const composerButtons = [];
export function registerComposerButton(fn, opts) { composerButtons.push({ fn: fn, side: (opts && opts.side) || 'left' }); }

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
  edit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
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
  try { const m = await import('https://esm.sh/marked@13?bundle'); if (m && m.marked) _md = (t) => m.marked.parse(String(t || '')); } catch (_) {}
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
  const opts = Object.assign({ placeholder: 'Message the agent…', suggestions: [], greeting: null, scheme: null, splash: false }, options);
  const listeners = {};
  let messages = [];
  let status = 'idle'; // idle | pending | streaming
  let abort = null;
  let attachedFiles = [];                                  // composer attachments (set via ctx.addFile)
  let selectedModel = opts.model || (opts.models && opts.models[0]) || null; // composer model picker
  // Agent the run is routed through (the composer's agent selector). Pinned for a session's life: once the
  // conversation has any messages, the selector locks (agentLocked()), matching "pick the agent only when
  // starting a new session". idOf-style values may be strings or { name, label, ... } records.
  let selectedAgent = opts.agent || (opts.agents && opts.agents[0]) || null;
  let selectedCapabilities = (opts.capabilities && opts.capabilities.slice()) || []; // composer capability multi-select

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
    const all = m.parts || [];
    // Suggested follow-ups render AFTER the action bar (subtle, trailing) — everything else inline.
    all.filter(p => p.type !== 'suggestions').forEach(p => { const r = (parts[p.type] || parts.text); row.append(r(p, ctxFor(m.role))); });
    if (status === 'idle') { const a = messageActions(m); if (a) row.append(a); }
    all.filter(p => p.type === 'suggestions').forEach(p => { const r = parts[p.type]; if (r) row.append(r(p, ctxFor(m.role))); });
    return row;
  }
  function messageActions(m) {
    const text = (m.parts || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
    const ctx = { message: m, text, copy, regenerate: () => regenerate(m), edit: () => beginEdit(m), controller, el, icon, md };
    const bar = el('div', { class: 'wbc-actions' });
    if (m.role === 'assistant') {
      bar.append(el('button', { class: 'wbc-act', title: 'Copy', html: ICON.copy, onClick: () => copy(text) }));
      bar.append(el('button', { class: 'wbc-act', title: 'Regenerate', html: ICON.refresh, onClick: () => regenerate(m) }));
    } else {
      bar.append(el('button', { class: 'wbc-act', title: 'Edit', html: ICON.edit, onClick: () => beginEdit(m) }));
    }
    actions.forEach(fn => { try { const n = fn(m, ctx); if (n) bar.append(n); } catch (_) {} });
    return bar.childNodes.length ? bar : null;
  }
  // Edit a user message: pull its text back into the composer and truncate from here (re-send to fork).
  function beginEdit(m) {
    const idx = messages.indexOf(m); if (idx < 0) return;
    const text = (m.parts || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
    messages = messages.slice(0, idx); render();
    composer._ta.value = text; composer._ta.focus(); composer._ta.dispatchEvent(new Event('input'));
  }

  function render() {
    // Splash mode: an empty conversation centers the composer (big, no headings) like a create page.
    if (opts.splash) root.classList.toggle('wbc-splash', messages.length === 0 && status === 'idle');
    convoInner.innerHTML = '';
    if (messages.length === 0) { convoInner.append(emptyState()); return; }
    messages.forEach(m => convoInner.append(renderMessage(m)));
    if (status === 'pending') convoInner.append(el('div', { class: 'wbc-msg assistant' }, [el('div', { class: 'wbc-bubble' }, [typing()])]));
    scrollToEnd();
  }
  function typing() { return el('div', { class: 'wbc-typing' }, [el('i'), el('i'), el('i')]); }
  function emptyState() {
    const wrap = el('div', { class: 'wbc-empty' });
    // Splash mode shows no heading/subheading — just the centered composer (+ optional suggestion chips).
    if (opts.greeting && !opts.splash) wrap.append(el('h3', null, opts.greeting.title || 'Start a chat'), el('p', null, opts.greeting.text || ''));
    if (opts.suggestions && opts.suggestions.length) {
      const s = el('div', { class: 'wbc-suggest' });
      opts.suggestions.forEach(t => s.append(el('button', { class: 'wbc-chip', onClick: () => submit(t) }, t)));
      wrap.append(s);
    }
    return wrap;
  }

  // ── composer ──
  // Layout: the bordered box (.wbc-composer-inner) is a COLUMN — the textarea is its own full-width row
  // on top, then a toolbar row (.wbc-composer-bar) underneath with a LEFT group (agent + model selectors)
  // and a RIGHT group (file/mic actions + the send button). This keeps the textarea full width instead of
  // being squished between side-by-side columns.
  function buildComposer() {
    injectStyle('composer-x', `.wbc-tray{display:flex;flex-wrap:wrap;gap:6px;max-width:var(--wbc-content-max);margin:0 auto 8px}
      .wbc-tray:empty{display:none} .wbc-chip-file{display:flex;align-items:center;gap:6px;border:1px solid var(--wbc-line);background:var(--wbc-panel);border-radius:8px;padding:4px 8px;font:500 12px var(--wbc-font);color:var(--wbc-ink)}
      .wbc-chip-file button{border:none;background:none;color:var(--wbc-dim);cursor:pointer;padding:0 2px}
      .wbc-composer-bar{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-top:8px}
      .wbc-tools{display:flex;align-items:center;gap:2px;min-width:0}
      .wbc-tools-right{flex:none}
      .wbc-tool{border:none;background:none;color:var(--wbc-dim);cursor:pointer;width:30px;height:30px;border-radius:8px;display:grid;place-items:center}
      .wbc-tool:hover{background:var(--wbc-line);color:var(--wbc-ink)} .wbc-tool svg{width:17px;height:17px}`);
    const wrap = el('div', { class: 'wbc-composer' });
    const tray = el('div', { class: 'wbc-tray' });
    const inner = el('div', { class: 'wbc-composer-inner' });
    const ta = el('textarea', { class: 'wbc-textarea', rows: '1', placeholder: opts.placeholder });
    const bar = el('div', { class: 'wbc-composer-bar' });
    const toolsLeft = el('div', { class: 'wbc-tools wbc-tools-left' });
    const toolsRight = el('div', { class: 'wbc-tools wbc-tools-right' });
    const send = el('button', { class: 'wbc-send', html: ICON.send, title: 'Send' });
    const grow = () => { ta.style.height = 'auto'; ta.style.height = Math.min(ta.scrollHeight, 200) + 'px'; };
    ta.addEventListener('input', grow);
    ta.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); fire(); } });
    send.addEventListener('click', fire);
    function fire() { const v = ta.value.trim(); if ((!v && !attachedFiles.length) || status !== 'idle') return; ta.value = ''; grow(); submit(v); }
    // file/mic actions sit to the LEFT of send, inside the right group.
    toolsRight.append(send);
    bar.append(toolsLeft, toolsRight);
    inner.append(ta, bar);
    wrap.append(tray, inner);
    // _tools (left) is the default mount target; _toolsRight receives side:'right' add-ons (before send).
    wrap._ta = ta; wrap._send = send; wrap._tray = tray; wrap._tools = toolsLeft; wrap._toolsRight = toolsRight;
    return wrap;
  }
  function renderTray() {
    const tray = composer._tray; tray.innerHTML = '';
    attachedFiles.forEach((f, i) => tray.append(el('span', { class: 'wbc-chip-file' }, [
      f.name || ('file ' + (i + 1)), el('button', { title: 'Remove', onClick: () => { attachedFiles.splice(i, 1); renderTray(); } }, '×')])));
  }
  // ctx handed to registered composer buttons (attachments, model selector, …)
  const composerCtx = {
    el, icon, get controller() { return controller; },
    addFile: (f) => { attachedFiles.push(f); renderTray(); },
    files: () => attachedFiles.slice(),
    // Append text into the composer (used by the mic/transcription add-on); keeps a space between chunks.
    insertText: (t) => { const ta = composer._ta; if (!ta || !t) return; ta.value = (ta.value && !/\s$/.test(ta.value) ? ta.value + ' ' : ta.value) + t; ta.dispatchEvent(new Event('input')); ta.focus(); },
    models: opts.models || [],
    model: () => selectedModel,
    setModel: (m) => { selectedModel = m; },
    // Agent selector hooks (consumed by the agent-selector composer add-on).
    agents: opts.agents || [],
    agent: () => selectedAgent,
    setAgent: (a) => { selectedAgent = a; if (opts.onAgent) try { opts.onAgent(a); } catch (e) {} },
    agentLocked: () => messages.length > 0,
    // Capability multi-select hooks (consumed by the capabilities-selector add-on). The catalog is the
    // toolkit list; admission(agentName) → 'all' | 'none' | [ids] gates what's selectable per driver.
    capabilityCatalog: opts.capabilityCatalog || [],
    capabilityAdmission: opts.capabilityAdmission || (() => 'all'),
    capabilities: () => selectedCapabilities.slice(),
    setCapabilities: (ids) => { selectedCapabilities = (ids || []).slice(); },
    onChange: (fn) => { (listeners['change'] = listeners['change'] || []).push(fn); },
    // Host-provided context picker (e.g. the cloud command-palette search). Returns Promise<item[]>; the
    // attachments add-on calls it instead of the native file dialog when present. null = native file input.
    pickContext: opts.onAttach || null,
    submit: (t) => submit(t),
  };
  function mountComposerButtons() {
    composerButtons.forEach(b => {
      try {
        const n = b.fn(composerCtx); if (!n) return;
        if (b.side === 'right') composer._toolsRight.insertBefore(n, composer._send);  // left of send
        else composer._tools.append(n);
      } catch (e) { try { console.error('[wbchat] composer button failed', e); } catch (_) {} }
    });
  }
  function setBusy(b) { composer._send.disabled = b; }

  // ── flow ──
  async function submit(text) {
    if (status !== 'idle') return;
    const files = attachedFiles.slice(); attachedFiles = []; renderTray();
    const userParts = [{ type: 'text', text }].concat(files.map(f => ({ type: 'file', name: f.name, mime: f.type })));
    const userMsg = { id: ++_seq, role: 'user', parts: userParts };
    messages.push(userMsg);
    emit('send', { text, files }); emit('change', { messages });
    status = 'pending'; setBusy(true); render();

    const assistant = { id: ++_seq, role: 'assistant', parts: [{ type: 'text', text: '' }] };
    let started = false;
    abort = new AbortController();
    const onDelta = (chunk) => {
      if (!started) { started = true; status = 'streaming'; messages.push(assistant); }
      assistant.parts[0].text += chunk; render();
    };
    try {
      const ret = await (opts.send ? opts.send(text, { delta: onDelta, signal: abort.signal, files, model: selectedModel, agent: selectedAgent, capabilities: selectedCapabilities.slice() }) : Promise.resolve('(no adapter wired)'));
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
    addMessage(m) { messages.push(normalize(m)); render(); emit('change', { messages }); return controller; },
    setMessages(list) { messages = (list || []).map(normalize); render(); emit('change', { messages }); return controller; },
    clear() { messages = []; render(); emit('change', { messages }); return controller; },
    submit(text) { submit(text); return controller; },
    stop() { if (abort) abort.abort(); status = 'idle'; setBusy(false); render(); return controller; },
    focus() { composer._ta.focus(); return controller; },
    // Agent the run routes through — read/set externally (e.g. opening a session pins its saved agent).
    get agent() { return selectedAgent; },
    setAgent(a) { selectedAgent = a; emit('change', { messages }); return controller; },
    on(evt, fn) { (listeners[evt] = listeners[evt] || []).push(fn); return controller; },
    destroy() { container.innerHTML = ''; },
    el, render,
  };
  function normalize(m) {
    if (m.parts) return { id: m.id || ++_seq, role: m.role, parts: m.parts, meta: m.meta };
    return { id: m.id || ++_seq, role: m.role, parts: [{ type: 'text', text: m.text || '' }], meta: m.meta };
  }
  mountComposerButtons(); // after composerCtx + controller exist (avoids TDZ)
  return controller;
}
