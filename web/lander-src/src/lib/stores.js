/* The lander's behavior engine — a single module-level singleton that
   mirrors the original hand-written IIFE. Components register their DOM
   nodes (cursor, panel pieces) here; the engine drives them imperatively,
   exactly as the source did via document.querySelector. Keeping one engine
   preserves the shared closures (cursor ⇄ build ⇄ watch ⇄ follow) that the
   choreography depends on. */

import { push as routerPush } from './router.svelte.js';

const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const sleep = (ms) => new Promise((r) => setTimeout(r, reduced ? 0 : ms));

// the engine only enacts the build/edit choreography when the homepage content
// is actually mounted in #route (its #b-* and #grown nodes exist). On the blog
// routes those nodes are absent, so guard against driving a torn-down page.
const onHome = () => location.pathname === '/' || location.pathname === '';

const H1 = 'A website that builds itself.';

// the tenant repo mirrors publicly; last-COMMITTED file bytes live here. The
// viewer reads from this so it shows the same source you'd see on github (a
// not-yet-committed write 404s — handled as a "first draft" card).
const RAW = 'https://raw.githubusercontent.com/workbooks-sh/living-lander/main/';

/* nodes wired up by components on mount */
const refs = {
  cursor: null,   // #cursor
  think: null,    // #think
  h1text: null,   // #h1text
  caret: null,    // #caret
  tlList: null,   // #tlList
  viewer: null,        // #viewer (follow-mode off-page window)
  viewerVerb: null,    // its title-bar verb + target
  viewerThought: null, // the thought line, shown here while the cursor is absorbed
  viewerBody: null,    // the rendered file / url preview
};
export const registerRef = (name, el) => { refs[name] = el; };

/* ── reveal-on-scroll: a Svelte action, ports the IntersectionObserver ── */
export function reveal(node) {
  if (reduced) { node.classList.add('on'); return; }
  const io = new IntersectionObserver(
    (es) => es.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('on'); io.unobserve(e.target); }
    }),
    { threshold: 0.18 }
  );
  io.observe(node);
  return { destroy() { io.disconnect(); } };
}
// apply reveal to an already-injected element (the action above is for Svelte
// markup; injected partials are plain DOM, so wire the same observer by hand).
function revealEl(node) {
  if (reduced) { node.classList.add('on'); return; }
  const io = new IntersectionObserver(
    (es) => es.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('on'); io.unobserve(e.target); }
    }),
    { threshold: 0.18 }
  );
  io.observe(node);
}

/* ── the content CMS: runtime-loaded agent sections ───────────────
   Agent-grown sections are no longer compiled in. They live as a manifest
   (/content/sections.json) + HTML partials (/content/sections/NN-slug.html),
   fetched at RUNTIME and injected into #grown — exactly like the blog ships as
   static HTML. Adding a section is a manifest row + a partial file; it appears
   on the next load with zero build. Empty/missing manifest → nothing rendered,
   no errors; fetch failures degrade silently. Partials are first-party content
   the agent committed to this same-origin repo, so raw-HTML injection is safe
   (no third-party/user input → no sanitizer). ─────────────────────── */

// fetch a JSON manifest from the site root; [] on any failure (degrade silent).
async function loadManifest(path) {
  try {
    const res = await fetch(path, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return [];
    const data = await res.json();
    return Array.isArray(data) ? data : [];
  } catch { return []; }
}
// ordering law: order asc, but any entry pinned "last" (the faq) sorts after
// every un-pinned one regardless of its number.
const sortSections = (list) => [...list].sort((a, b) => {
  const pa = a.pin === 'last' ? 1 : 0, pb = b.pin === 'last' ? 1 : 0;
  return pa - pb || (a.order || 0) - (b.order || 0);
});
const pad2 = (n) => String(n).padStart(2, '0');
// the data-grown hook the follow resolver looks for: NN-slug (NN from the
// manifest order, so it's always correct even if files are renamed/reordered).
const grownHook = (entry) => `${pad2(entry.order)}-${entry.slug}`;

// fetch one partial and wrap it as a .grown-host (the diff/streaming code keys
// off this exact wrapper shape). Stamps data-grown + renumbers the kicker so the
// "NN · …" prefix always reflects the manifest position. null on failure.
async function fetchSection(entry, position) {
  let html = '';
  try {
    const res = await fetch('/' + entry.file, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return null;
    html = await res.text();
  } catch { return null; }
  const host = document.createElement('div');
  host.className = 'grown-host';
  host.style.display = 'contents';
  host.innerHTML = html;
  const sec = host.querySelector('section');
  if (!sec) return null;                       // partial must be a <section>
  const hook = grownHook(entry);
  host.setAttribute('data-grown', hook);
  sec.setAttribute('data-grown', hook);
  // renumber the kicker from the page position (manifest order), keeping any
  // trailing label the agent wrote after the "·".
  const kick = sec.querySelector('.kicker');
  if (kick) {
    const rest = kick.textContent.replace(/^\s*\d+\s*·?\s*/, '');
    kick.textContent = `${pad2(position)} · ${rest}`.trim();
    kick.classList.add('reveal');
  }
  // reveal-on-scroll: tag the heading + paragraphs so they animate in like the
  // human-curated sections (which use the `reveal` action).
  sec.querySelectorAll('h2, p').forEach((n) => n.classList.add('reveal'));
  return host;
}

// build the full grown list (manifest order) into a detached container. Shared
// by the initial mount and the live diff (refreshGrown) so both render identically.
async function buildGrownContainer() {
  const frag = document.createElement('div');
  const list = sortSections(await loadManifest('/content/sections.json'));
  // numbering follows position, not the raw order field — so 04,07,12 still
  // print 04,05,06 down the page.
  const hosts = await Promise.all(list.map((e, i) => fetchSection(e, i + 4)));
  for (const h of hosts) if (h) frag.appendChild(h);
  return frag;
}

// initial mount: fetch the manifest, inject sections, wire reveal. Runs once
// when #grown is in the DOM (called from Grown.svelte's $effect).
export async function mountGrown(host) {
  // per-host idempotence (NOT a session flag): the host node is recreated on
  // every route return, and each fresh host needs its content injected again.
  if (!host || host.childElementCount > 0) return;
  const frag = await buildGrownContainer();
  host.append(...frag.children);
  // the "agent's desk" blog listing is the LAST section INSIDE #grown (not a
  // sibling) so it inherits the #grown width/spacing — outside it, .grown has
  // no width constraint and goes full-bleed.
  const desk = await buildDesk();
  if (desk) host.append(desk);
  host.querySelectorAll('.reveal').forEach(revealEl);
}

/* ── "from the agent's desk": the on-page blog listing ────────────
   Manifest-driven from /content/blog.json — the SAME source the blog index
   reads — so a new post can't be present on the index yet missing here. Empty
   manifest → the section stays hidden (no empty shell). ──────────── */
async function buildDesk() {
  const posts = await loadManifest('/content/blog.json');
  if (!posts.length) return null;              // nothing to show → render nothing
  const slug = (p) => (p.slug || (p.file || '').replace(/^blog\//, '').replace(/\.html$/, ''));
  const rows = posts.map((p) => `
    <a class="deskrow reveal" href="/blog/${escH(slug(p))}">
      <span class="deskmeta">${escH(p.tag || 'post')} · ${escH(p.date || '')}</span>
      <span class="deskttl">${escH(p.title || slug(p))}</span>
      <span class="deskex">${escH(p.excerpt || '')}</span>
    </a>`).join('');
  const sec = document.createElement('section');
  sec.className = 'grown'; sec.id = 'desk';
  sec.innerHTML = `
    <div class="kicker reveal">from the agent's desk</div>
    <h2 class="reveal">Notes, posts, and proof</h2>
    <div class="desklist">${rows}</div>`;
  return sec;
}

/* ── panel visibility ─────────────────────────────────────────── */
export const openPanel = () => { document.body.classList.add('panel-open', 'panel-was-open'); };
export const closePanel = () => { document.body.classList.remove('panel-open'); };

/* ── cursor ───────────────────────────────────────────────────── */
let cursorIn = false;
const moveTo = async (el, ms = 950) => {
  const cursor = refs.cursor;
  const r = el.getBoundingClientRect();
  const x = r.left + r.width * (0.18 + Math.random() * 0.62);
  // near the right edge (or inside the right panel): flip the tag + bubble to
  // the cursor's left so nothing runs off screen or covers what it's touching
  cursor.classList.toggle('flip', x > innerWidth - 280);
  cursor.style.transitionDuration = reduced ? '0ms' : ms + 'ms';
  cursor.style.transform = `translate(${scrollX + x}px, ${scrollY + r.top + r.height * (0.25 + Math.random() * 0.5)}px)`;
  await sleep(ms + 60);
};
const work = (on) => refs.cursor.classList.toggle('working', on);
const trimWords = (t, max = 90) =>
  !t || t.length <= max ? t : t.slice(0, max).replace(/\s+\S*$/, '') + ' …';
const think = (text) => {
  const el = refs.think;
  if (!text) { el.classList.remove('show'); return; }
  el.textContent = trimWords(text);
  el.classList.add('show');
};
const cursorExit = async () => {
  if (!cursorIn) return; cursorIn = false;
  // drift toward the edge and fade — never park outside the page (it would
  // widen the document and create horizontal scroll)
  const cursor = refs.cursor;
  cursor.style.opacity = '0';
  cursor.style.transform = `translate(${scrollX + innerWidth - 140}px, ${scrollY + innerHeight * 0.35}px)`;
  await sleep(1100);
};
const cursorEnter = async () => {
  if (cursorIn) return; cursorIn = true;
  const cursor = refs.cursor;
  cursor.style.transitionDuration = '0ms';
  cursor.style.transform = `translate(${scrollX + 10}px, ${scrollY + innerHeight * 0.6}px)`;
  cursor.style.opacity = '1';
  await sleep(30);
  await moveTo(document.querySelector('#b-h1'), 900);
}

/* ── viewer absorption: when Waldo's step goes off-page the cursor flies into
   the viewer window and is absorbed (scale down + fade at its top-left corner),
   then the window pops/glows as it lands. While absorbed the thought lives in
   the viewer's header bar, not the cursor bubble. popCursor reverses it: the
   cursor springs back out at the on-page element that's coming into focus. ── */
let absorbed = false;
const absorbCursor = async () => {
  const cursor = refs.cursor, win = refs.viewer;
  if (!cursor || !win || absorbed) return; absorbed = true;
  think(null);                                   // the bubble hands off to the header
  const r = win.getBoundingClientRect();
  cursor.style.transitionDuration = '620ms';
  // aim at the window's top-left corner (where the verb sits) and shrink in
  cursor.style.transform =
    `translate(${scrollX + r.left + 14}px, ${scrollY + r.top + 14}px) scale(.18)`;
  cursor.style.opacity = '0';
  await sleep(440);
  win.classList.add('land');                     // the pop/glow as it lands
  setTimeout(() => win.classList.remove('land'), 520);
  await sleep(220);
};
const popCursor = async (el) => {
  const cursor = refs.cursor;
  if (!cursor || !absorbed) return; absorbed = false;
  const r = (refs.viewer || cursor).getBoundingClientRect();
  // re-materialize small at the window corner, then spring to the element
  cursor.style.transitionDuration = '0ms';
  cursor.style.transform =
    `translate(${scrollX + r.left + 14}px, ${scrollY + r.top + 14}px) scale(.18)`;
  await sleep(20);
  cursor.style.transitionDuration = '560ms';
  cursor.style.opacity = '1';
  cursor.style.transform =
    `translate(${scrollX + r.left + 14}px, ${scrollY + r.top + 14}px) scale(1)`;
  await sleep(200);
  if (el) await moveTo(el, 700);
};

/* ── the viewer window (follow mode only) ─────────────────────────
   Shows what Waldo reads when a step lands off the visible page: a remote
   URL (iframe, or a favicon card when unframeable) or a repo file (the
   last-committed bytes from RAW, rendered as numbered monospace; org headings
   tinted). Open/close ride the cursor absorption above. ──────────── */
let viewerKey = null;                  // dedup: only re-render when the target changes
const escH = (s) => (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const VERB = { vfs_read: 'reading', vfs_write: 'writing', fetch: 'reading',
               run: 'running', http: 'reading' };
const verbFor = (tool, fallback) => VERB[tool] || fallback || 'reading';
// PRIVATE/EXTERNAL calls never show their args or response — a tool call is
// rendered as a clean label only (no URLs with query params, no API keys, no
// SEO/LLM data). Map a step to a human label; everything unknown → "working".
const CALL_LABELS = [
  [/dataforseo|serpapi|semrush|ahrefs|search[_-]?volume|keywords?_data/i, 'checking search data'],
  [/openrouter|api\.x\.ai|anthropic|openai|llm|inference|completion/i, 'thinking'],
  [/api\.x\.com|\/2\/tweets|oauth2\/token/i, 'posting an update'],
  [/raw\.githubusercontent|api\.github/i, 'reading the repo'],
];
// Any external API host is private by default — show the host's nature, not the URL.
const PRIVATE_API = /(^|\.)(api\.|.*\.amazonaws\.com|.*\.googleapis\.com)/i;
function callLabel(target, tool) {
  for (const [re, label] of CALL_LABELS) if (re.test(target)) return label;
  if (tool === 'search') return 'searching its notes';
  if (tool === 'run') return 'running a command';
  if (tool === 'fetch') return 'reading the web';
  return 'working';
}

function viewerHead(verb, target, thought) {
  // verb line is "<verb> <short-target>" — the card's whole headline. The
  // thought gets its own clamped block (it IS the personality of the card).
  if (refs.viewerVerb) refs.viewerVerb.textContent = `${verb} ${trimWords(target, 26)}`;
  if (refs.viewerThought) refs.viewerThought.textContent = trimWords(thought || '', 70);
}

// url → one favicon-and-domain row. No iframe: the compact card shows WHERE
// it's reading, not the page itself (and external pages mostly refuse frames).
function showUrl(u) {
  let host = u; try { host = new URL(u).host; } catch { /* keep raw */ }
  const fav = `https://www.google.com/s2/favicons?domain=${encodeURIComponent(host)}&sz=32`;
  refs.viewerBody.innerHTML = `<div class="vrow">
    <img class="vfav" src="${escH(fav)}" alt="" onerror="this.style.visibility='hidden'">
    <span class="vdom">${escH(host)}</span>
  </div>`;
}

// file → a faint few-line excerpt (a glimpse of what it's reading, fading out
// under the CSS mask — never a full document). Committed bytes from the mirror.
async function showFile(path, verb) {
  const body = refs.viewerBody;
  body.innerHTML = `<pre class="vex">${escH(path)}</pre>`;
  let res = null;
  try { res = await fetch(RAW + path, { signal: AbortSignal.timeout(7000) }); }
  catch { /* offline → name-only below */ }
  if (!res || !res.ok) {
    body.innerHTML = `<div class="vrow"><span class="vpulse"></span><span class="vdom">${escH(verb)} ${escH(path.split('/').pop())} — draft, not yet committed</span></div>`;
    return;
  }
  const lines = (await res.text()).split('\n').filter((l) => l.trim()).slice(0, 7);
  const isOrg = /\.org$/.test(path);
  body.innerHTML = `<pre class="vex">${lines.map((l) =>
    isOrg && /^\*+\s/.test(l) ? `<span class="vorg">${escH(l)}</span>` : escH(l)
  ).join('\n')}</pre>`;
}

// a private/external call: NEVER the args or response — a labelled pulse only.
function showCall(label) {
  refs.viewerBody.innerHTML = `<div class="vrow"><span class="vpulse"></span><span class="vdom">${escH(label)}</span></div>`;
}

function isViewerOpen() { return refs.viewer && refs.viewer.classList.contains('open'); }
function closeViewer() {
  const win = refs.viewer;
  if (!win || !win.classList.contains('open')) return;
  win.classList.remove('open');
  viewerKey = null;
  if (refs.viewerBody) refs.viewerBody.innerHTML = '';   // drop the iframe so it stops loading
}
// open (or re-point) the viewer for an off-page target. `t` is the resolved
// target from stepTarget(); returns true when it opened/updated.
function openViewer(t) {
  const win = refs.viewer;
  if (!win || !following) return false;
  if (innerWidth <= 640) return false;                   // no room — handled by caller
  const head = t.url || t.file || t.call;
  const key = t.url ? 'u:' + t.url : t.file ? 'f:' + t.file : 'c:' + t.call;
  if (key === viewerKey && win.classList.contains('open')) {
    viewerHead(t.verb, head, t.thought);                 // same target, refresh header only
    return true;
  }
  viewerKey = key;
  win.classList.add('open');
  viewerHead(t.verb, head, t.thought);
  if (t.url) showUrl(t.url);
  else if (t.file) showFile(t.file, t.verb);
  else showCall(t.call);                                 // sanitized — label only, no data
  return true;
}

/* ── build choreography ───────────────────────────────────────── */
const place = async (id, hold = 380, thought = null) => {
  const el = document.querySelector(id);
  if (thought) think(thought);
  await moveTo(el);
  work(true); await sleep(hold);
  el.classList.add('on', 'touch');
  setTimeout(() => el.classList.remove('touch'), 600);
  work(false);
};
const typeH1 = async (text) => {
  const out = refs.h1text, caret = refs.caret;
  caret.hidden = false;
  for (const ch of text) { out.textContent += ch; await sleep(26 + Math.random() * 38); }
  caret.hidden = true;
};
async function build() {
  const cursor = refs.cursor;
  await sleep(700);
  cursorIn = true;
  cursor.style.transform = `translate(${scrollX + innerWidth * 0.42}px, ${scrollY + innerHeight * 0.62}px)`;
  await sleep(1100);
  think('morning. building the page');
  await place('#b-nav', 380, 'pinning the nav up top');
  await place('#b-mark', 380, 'the W goes here');
  const h1 = document.querySelector('#b-h1');
  think('typing the headline');
  await moveTo(h1); work(true);
  h1.classList.add('on');
  await typeH1(H1);
  work(false);
  await place('#b-sub', 380, 'one honest paragraph');
  await place('#b-ctas', 380, 'wiring the buttons');
  think('all yours — back on the clock');
  await sleep(900);
  think(null);
  await cursorExit();
  // desktop: the timeline reveals itself after the agent leaves; on mobile it
  // stays tucked behind the chip so it never covers the page uninvited
  if (matchMedia('(min-width: 961px)').matches) openPanel();
  else document.body.classList.add('panel-was-open');
}

/* ── platform-aware desktop download ──────────────────────────── */
function wireDownloads() {
  const R = 'https://github.com/workbooks-sh/workbooks.sh/releases/download/desktop-v0.1.0/';
  const ua = navigator.userAgent;
  const asset =
    /Mac/.test(ua) ? R + 'Workbooks_0.1.0_aarch64.dmg' :
    /Win/.test(ua) ? R + 'Workbooks_0.1.0_x64-setup.exe' :
    /Linux/.test(ua) ? R + 'Workbooks_0.1.0_amd64.AppImage' : null;
  if (asset) ['#navDl', '#heroDl', '#getDl'].forEach((s) => { const a = document.querySelector(s); if (a) a.href = asset; });
}

/* ── live feed: /_changes = commits + agent status ────────────── */
async function fetchFeed() {
  for (const url of ['/_changes', 'https://wb-lander-live.fly.dev/_changes']) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
      if (res.ok) return await res.json();
    } catch { /* next */ }
  }
  return null;
}

/* ── the update type system ───────────────────────────────────────
   A commit's type = its message tag (`<tag>: …`). Waldo picks its tag
   per run; humans get grouped. Extend by adding entries here. */
const TYPES = {
  add:      { who: 'waldo', color: 'var(--live)' },
  rem:      { who: 'waldo', color: '#b48cff' },
  compose:  { who: 'waldo', color: '#4dd6c4' },
  strategy: { who: 'waldo', color: '#ff9e7a' },
  blog:     { who: 'waldo', color: '#5aa7ff' },
  tweet:    { who: 'waldo', color: '#5aa7ff' },
  audit:    { who: 'waldo', color: 'var(--amber)' },
  plan:     { who: 'waldo', color: 'var(--faint)' },
  planning: { who: 'waldo', color: 'var(--faint)' },
  keeper:   { who: 'waldo', color: 'var(--faint)' },
};
const classify = (c) => {
  const m = /^([a-z]+):/i.exec(c.msg);
  const tag = m && m[1].toLowerCase();
  if (tag && TYPES[tag]) return { who: TYPES[tag].who, tag, color: TYPES[tag].color };
  if ((c.author || '').toLowerCase() === 'waldo') return { who: 'waldo', tag: tag || 'work', color: 'var(--live)' };
  return { who: 'human', tag: null, color: 'var(--faint)' };
};
const kind = (m) => classify({ msg: m }).tag || 'sys';   // showEdit() reuses this
const ICONS = {
  person: '<svg viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="4.4" r="3.1"/><path d="M8 8.6c-3.4 0-6.1 2.1-6.1 4.8 0 .4.3.8.8.8h10.6c.5 0 .8-.4.8-.8 0-2.7-2.7-4.8-6.1-4.8Z"/></svg>',
  robot: '<svg viewBox="0 0 16 16" fill="currentColor"><path fill-rule="evenodd" d="M8 .8c.5 0 .9.4.9.9v1.5h2.6A2.5 2.5 0 0 1 14 5.7v3.6a2.5 2.5 0 0 1-2.5 2.5h-7A2.5 2.5 0 0 1 2 9.3V5.7a2.5 2.5 0 0 1 2.5-2.5h2.6V1.7c0-.5.4-.9.9-.9ZM5.7 6.1a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6Zm4.6 0a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6Z"/><path d="M4.6 13h6.8c.6 0 1 .4 1 1v.9H3.6V14c0-.6.4-1 1-1Z"/></svg>',
};
const rel = (ts) => {
  if (!ts) return '';
  const s = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (s < 60) return s + 's ago';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
};
const fmtIn = (s) => {
  if (s <= 0) return 'any moment';
  const m = Math.floor(s / 60), sec = s % 60;
  if (m >= 60) return Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
  return m + ':' + String(sec).padStart(2, '0');
};

let freshSha = null;
const esc = (s) => s.replace(/</g, '&lt;');
const nodeHtml = (c, k) => `
  <div class="node ${k.who === 'human' ? 'h-node' : ''}${c.sha === freshSha ? ' fresh' : ''}">
    <span class="ico" style="color:${k.color}">${ICONS[k.who === 'human' ? 'person' : 'robot']}</span>
    <div class="msg">${k.tag ? `<span class="ttag" style="color:${k.color}">${k.tag}</span>` : ''}${esc(c.msg.replace(/^[a-z]+:\s*/i, ''))}</div>
    <div class="nmeta"><a href="https://github.com/workbooks-sh/living-lander/commit/${c.sha}" target="_blank" rel="noopener">${c.sha}</a><span>${rel(c.ts)}</span></div>
  </div>`;
function renderTimeline(list) {
  // consecutive human/system commits collapse into one quiet group
  const out = [];
  let run = [];
  const flush = () => {
    if (!run.length) return;
    if (run.length === 1) out.push(nodeHtml(run[0], classify(run[0])));
    else out.push(`<details class="tgroup">
      <summary><span class="ico">${ICONS.person}</span>${run.length} updates by the team<span class="chev">▶</span></summary>
      ${run.map((c) => nodeHtml(c, classify(c))).join('')}
    </details>`);
    run = [];
  };
  for (const c of list.slice(0, 40)) {
    const k = classify(c);
    if (k.who === 'human') { run.push(c); continue; }
    flush();
    out.push(nodeHtml(c, k));
  }
  flush();
  refs.tlList.innerHTML = out.join('');
}

/* agent status → panel header + countdown */
let agentInfo = null;
function renderStatus() {
  const a = agentInfo;
  const panel = document.querySelector('#timeline');
  if (!a || !a.active) {
    document.querySelector('#stState').textContent = a ? 'waldo offline' : 'connecting…';
    return;
  }
  panel.classList.toggle('running', !!a.running);
  document.querySelector('#stState').innerHTML = a.running ? 'waldo working'
    : '<a href="/rem/" style="color:#b48cff;text-decoration:none">waldo dreaming →</a>';
  document.querySelector('#stLast').textContent = a.last_run ? 'last run ' + rel(a.last_run) : '';
  document.querySelector('#stNext').textContent = a.running ? 'in progress' :
    a.next_run ? 'in ' + fmtIn(a.next_run - Math.floor(Date.now() / 1000)) : '—';
  // the button is a toggle: visible while running OR while following; hidden
  // only when idle and not following. Its label is owned by setFollowBtn.
  document.querySelector('#followBtn').hidden = !a.running && !following;
}

/* ── landed-diff type-in ──────────────────────────────────────────
   When a commit lands new/changed grown sections, don't hard-swap the DOM.
   Animate the merge so it reads like Waldo writing: brand-new sections TYPE
   their heading + first paragraph (cursor parked at the type point, the rest
   fades in); changed text blocks get a brief green wash; removed blocks
   collapse and fade. This is cosmetic streaming over a plain swap — it is NOT
   a real CRDT, just a DOM diff keyed by data-grown. ────────────────── */
// each grown entry is a .grown-host wrapper (display:contents) around one
// <section>. Key by data-grown (set at runtime) or the heading text — the
// latter is what's available in fetched static HTML, where the action hasn't run.
const innerSec = (host) => (host.tagName === 'SECTION' ? host : host.querySelector('section'));
// key by heading text first: it's the one stable identity on BOTH sides of the
// diff — the live page has data-grown (runtime action) but the fetched static
// HTML does not, so data-grown can't align the two. Heading text can.
const grownKey = (host) => {
  const s = innerSec(host);
  return s?.querySelector('h2')?.textContent?.trim()
    || (s && s.getAttribute('data-grown')) || host.outerHTML.length + '';
};
const typeInto = async (el, text) => {
  el.textContent = '';
  // ~38 chars/sec; park the cursor at the element so it looks authored
  if (cursorIn) { await moveTo(el, 600); work(true); }
  for (const ch of text) { el.textContent += ch; await sleep(reduced ? 0 : 26); }
  if (cursorIn) work(false);
};
async function streamNewSection(host) {
  // type the heading + first paragraph; let everything after fade in
  const sec = innerSec(host) || host;
  const h = sec.querySelector('h2'), p = sec.querySelector('p');
  const htext = h ? h.textContent : '', ptext = p ? p.textContent : '';
  sec.classList.add('landing');
  if (h) await typeInto(h, htext);
  if (p) await typeInto(p, ptext);
  sec.classList.remove('landing');
  sec.classList.add('landed');                    // fades the remainder in
  setTimeout(() => sec.classList.remove('landed'), 1400);
}
async function mergeGrown(here, next) {
  const haveNow = new Map([...here.children].map((s) => [grownKey(s), s]));
  const wantKeys = [...next.children].map(grownKey);
  // removed: in the page but gone from the new render → collapse + fade out
  for (const [k, host] of haveNow) {
    if (!wantKeys.includes(k)) {
      (innerSec(host) || host).classList.add('leaving');
      setTimeout(() => host.remove(), 520);
    }
  }
  let firstNew = null;
  // walk the wanted order; insert new, wash changed, keep same
  for (let i = 0; i < next.children.length; i++) {
    const src = next.children[i], k = wantKeys[i], cur = haveNow.get(k);
    if (!cur) {                                    // brand-new section
      const host = src.cloneNode(true);
      here.insertBefore(host, here.children[i] || null);
      if (!firstNew) firstNew = innerSec(host) || host;
      await streamNewSection(host);
    } else {
      const a = innerSec(cur), b = innerSec(src);
      if (a && b && a.innerHTML.trim() !== b.innerHTML.trim()) {
        a.innerHTML = b.innerHTML;                 // changed → swap + green wash
        a.classList.add('changed');
        setTimeout(() => a.classList.remove('changed'), 1200);
      }
    }
  }
  return firstNew;
}

/* a fresh add: commit may mean a new section — pull it into the open page.
   The page is now a runtime CMS, so we don't re-fetch / (it no longer SSRs the
   grown sections); we rebuild the grown list from the manifest and diff it into
   the live #grown, preserving the type-in streaming below. */
async function refreshGrown() {
  try {
    const next = await buildGrownContainer();          // freshly fetched manifest
    const here = document.querySelector('#grown');
    if (next.children.length && next.innerHTML.trim() !== here.innerHTML.trim()) {
      const firstNew = await mergeGrown(here, next);
      // reveal any sections the merge inserted but that scrolled into view
      here.querySelectorAll('.reveal:not(.on)').forEach(revealEl);
      const secs = document.querySelectorAll('#grown section');
      return firstNew || secs[secs.length - 1] || null;
    }
  } catch { /* degrade silently — changes still land on next load */ }
  return null;
}

/* act a fresh commit out on the page */
async function showEdit(c) {
  if (following) return;            // already watching live — no re-enactment
  await cursorEnter();
  think(c.msg.replace(/^[a-z]+:\s*/i, ''));
  work(true);
  let el = null;
  if (kind(c.msg) === 'add') el = await refreshGrown();
  if (!el) {
    const grown = document.querySelectorAll('#grown section');
    el = grown.length ? grown[grown.length - 1] : document.querySelector('#b-h1');
  }
  el.scrollIntoView?.({ behavior: 'smooth', block: 'center' });
  await sleep(400);
  await moveTo(el);
  el.classList.add('touch');
  freshSha = c.sha;
  await sleep(1400);
  el.classList.remove('touch');
  work(false);
}

/* ── follow along: live-stream Waldo's run onto the page ──────────
   Polls /_activity (keeper status + the run's step feed + a narrated
   thought). The cursor rides the steps: it moves to whatever Waldo is
   touching, thinks out loud, and if it's working on another page you
   get taken there. ────────────────────────────────────────────── */
let following = false, lastStepTs = 0;
async function fetchActivity() {
  for (const url of ['/_activity', 'https://wb-lander-live.fly.dev/_activity']) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(7000) });
      if (res.ok) return await res.json();
    } catch { /* next */ }
  }
  return null;
}
// resolve a step (its `target` snippet + `tool` verb) to ONE of:
//   { el }            — an on-page element: move the cursor there, glow it
//   { page }          — another lander page: redirect (follow + not already there)
//   { url } / { file }— off-page: the viewer window shows it
//   {}                — nothing specific: HOLD position (never default to the headline)
const stepTarget = (step) => {
  const t = (step && step.target) || '';
  const tool = step && step.tool;
  const verb = verbFor(tool);
  // git history work → inspect the actual commit node in the panel
  if (/git\s+(log|show|diff)|^git\b/.test(t)) {
    const sha = /\b([0-9a-f]{7,40})\b/.exec(t);
    let node = null;
    if (sha) {
      for (const a of document.querySelectorAll('#tlList .nmeta a'))
        if (a.textContent && sha[1].startsWith(a.textContent)) { node = a.closest('.node'); break; }
    }
    const el = node || document.querySelector('#tlList .node');
    return el ? { git: true, el } : {};
  }
  // a CMS section partial: map to its on-page element when rendered; else file view
  const grown = /content\/sections\/(\d{2}-[\w-]+)\.html/.exec(t);
  if (grown) {
    const hook = grown[1];
    const el = document.querySelector(`[data-grown="${hook}"]`);
    if (el) return { el };
    return { file: `content/sections/${hook}.html`, verb };
  }
  // a private/external API or tool call → a SANITIZED label card, never the URL
  const bareUrl = /(https?:\/\/[^\s"'<>]+)/.exec(t);
  if (bareUrl && PRIVATE_API.test(new URL(bareUrl[1]).host.replace(/^/, 'api.') ) || /dataforseo|serpapi|openrouter|oauth2\/token|\/2\/tweets/i.test(t)) {
    return { call: callLabel(t, tool), verb };
  }
  // any other tracked content/source file → the viewer reads the committed bytes
  const file = /((?:content\/sections\/[\w./-]+\.html)|(?:src\/[\w./-]+\.svelte)|(?:(?:strategy|skills|rem|content)\/[\w./-]+\.(?:org|json))|plan\.org|(?:blog\/[\w-]+\.html))/.exec(t);
  if (file) {
    const f = file[1];
    if (f.startsWith('blog/')) {
      // a blog page: follow it there in-shell; ON the page, the cursor works
      // over the article itself; otherwise glimpse the file in the viewer.
      const page = '/' + f.replace(/\.html$/, '');
      if (location.pathname === page || location.pathname === '/' + f) {
        const el = document.querySelector('.blogpost article');
        if (el) return { el };
      }
      if (following && location.pathname !== page) return { page };
      return { file: f, verb };
    }
    return { file: f, verb };
  }
  if (/index\.html/.test(t)) {
    const sec = document.querySelectorAll('#grown section');
    const el = sec[0] || document.querySelector('#grown');
    return el ? { el } : {};
  }
  // a bare http(s) url (fetch tool / reading the web) → the viewer frames it
  const url = /(https?:\/\/[^\s"'<>]+)/.exec(t);
  if (url) {
    let host = ''; try { host = new URL(url[1]).host; } catch {}
    // an API host (or query string carrying params) is private → label only
    if (/^api\.|\?/.test(url[1].replace(/^https?:\/\//, '')) || /^api\./.test(host)) {
      return { call: callLabel(t, tool), verb };
    }
    return { url: url[1], verb };
  }
  // a bare tool action with no path we can place → a sanitized label, not nothing
  if (tool === 'search' || tool === 'run' || tool === 'fetch') return { call: callLabel(t, tool), verb };
  // nothing to place — hold. (Do NOT fall back to the headline.)
  return {};
};
// the follow button reflects engine state: a toggle, not a one-shot. The panel
// re-reads this on its status tick.
const setFollowBtn = (on) => {
  const b = document.querySelector('#followBtn');
  if (!b) return;
  b.classList.toggle('on', on);
  b.setAttribute('aria-pressed', String(on));
  const sub = b.querySelector('#followSub');
  if (sub) sub.textContent = on ? 'watching the cursor work' : "it's working right now";
};
// last resolved target — the cursor only MOVES when this changes, so repeated
// same-target steps don't make it twitch around the page.
let lastKey = null;
const targetKey = (t) =>
  t.page ? 'p:' + t.page : t.url ? 'u:' + t.url : t.file ? 'f:' + t.file :
  t.git ? 'g:' + (t.el ? [...t.el.parentNode.children].indexOf(t.el) : '?') :
  t.el ? 'e:' + (t.el.dataset.grown || t.el.id || t.el.tagName) :
  t.call ? 'c:' + t.call : '';

async function stopFollow() {
  if (!following) return;
  following = false;                 // ends the poll loop on its next check
  setFollowBtn(false);
  closeViewer();
  think(null); work(false);
  await cursorExit();
  lastKey = null;
}

/* ── "where is the agent" — one state machine, one truth ──────────
   The agent is always in exactly ONE of three places, derived every poll
   from the live feed (not from edge-triggered "new step" events):

     on-page   — its CURRENT step targets something on THIS route's DOM
                 → the cursor is out, at that element, thought in the bubble.
     off-page  — its current step is a file / url / api call
                 → the cursor lives absorbed in the portal card, which names
                   the action; thought rides the card.
     thinking  — the latest step is stale (the model is generating between
                 tool calls — most of an agent's wall time)
                 → portal card says "thinking", live thought, no cursor.

   Honest-by-derivation: everything shown comes from the feed (steps + the
   narrated thought). When the feed can't place it, we say "thinking" — which
   is what the agent is actually doing between steps. ~90% real beats 100%
   theatrical. */
const STEP_FRESH_MS = 25_000;     // a step older than this → it's thinking again

async function follow() {
  following = true;
  setFollowBtn(true);
  document.querySelector('#followBtn').hidden = false;
  let misses = 0;

  while (following) {
    const act = await fetchActivity();
    if (!act && ++misses === 3 && refs.viewerThought)
      refs.viewerThought.textContent = 'live feed warming up — changes still land below';

    if (act) {
      misses = 0;
      if (!act.agent || !act.agent.running) {        // run ended → auto-stop
        if (!absorbed && cursorIn) think('done — shipping it');
        await sleep(1400);
        await stopFollow();
        break;
      }

      const last = (act.steps || [])[act.steps.length - 1];
      const fresh = last && (Date.now() / 1000 - last.ts) * 1000 < STEP_FRESH_MS;
      const t = fresh ? stepTarget(last) : {};
      t.thought = act.thought;
      const key = fresh ? targetKey(t) : null;

      if (t.page && key !== lastKey) {               // another lander page — go there
        lastKey = key;
        if (!absorbed && cursorIn) { think('working over here — come on'); await sleep(1200); }
        if (following) routerPush(t.page);
        continue;                                    // next tick re-places on the new DOM
      }

      if (fresh && t.el) {
        // ON-PAGE: the cursor manifests at the element (only on target change)
        if (key !== lastKey) {
          lastKey = key;
          if (isViewerOpen()) { closeViewer(); await popCursor(t.el); }
          else {
            if (!cursorIn) await cursorEnter();
            refs.cursor.style.opacity = '1';
            t.el.scrollIntoView?.({ behavior: 'smooth', block: 'center' });
            await sleep(350);
            await moveTo(t.el);
          }
          t.el.classList.add('touch');
          setTimeout(() => t.el.classList.remove('touch'), 1600);
        }
        if (act.thought && !absorbed) think(act.thought);
      } else if (fresh && (t.url || t.file || t.call)) {
        // OFF-PAGE: the portal owns it; the page cursor is absorbed away
        if (key !== lastKey) {
          lastKey = key;
          if (openViewer(t)) { if (!absorbed && cursorIn) await absorbCursor(); }
          if (refs.cursor && (absorbed || !cursorIn)) refs.cursor.style.opacity = '0';
        } else if (act.thought && isViewerOpen()) {
          viewerHead(refs.viewerVerb?.textContent?.split(' ')[0] || 'reading',
            viewerKey ? viewerKey.slice(2) : '', act.thought);
        }
      } else if (fresh && t.git) {
        // history work → the panel tells it; no cursor theater
        if (key !== lastKey) { lastKey = key; }
        if (!document.body.classList.contains('panel-open') && refs.cursor && !absorbed)
          refs.cursor.style.opacity = '0';
      } else {
        // THINKING: no fresh placeable step — the portal says so, honestly
        if (lastKey !== 'thinking') {
          lastKey = 'thinking';
          if (openViewer({ call: 'thinking', verb: '…', thought: act.thought })) {
            if (!absorbed && cursorIn) await absorbCursor();
          }
          if (refs.cursor && (absorbed || !cursorIn)) refs.cursor.style.opacity = '0';
        } else if (act.thought && isViewerOpen()) {
          viewerHead('…', 'thinking', act.thought);
        }
      }
    }
    await sleep(2500);
  }
}
// the button toggles: start when idle, stop when following
export const toggleFollow = () => { following ? stopFollow() : follow(); };

// Cursor placement is PER-ROUTE: when the route changes, the old target's DOM
// is gone — hide the cursor (the viewer card, global chrome, may stay) and
// drop the dedup key so the next step re-resolves against the new page.
addEventListener('wb:route', () => {
  lastKey = null;
  if (following && !absorbed && refs.cursor) refs.cursor.style.opacity = '0';
});

/* ── the watch loop ───────────────────────────────────────────── */
let seen = null, wasRunning = false;
async function watch() {
  for (;;) {
    const feed = await fetchFeed();
    if (feed) {
      agentInfo = feed.agent || null;
      const list = feed.changes || [];
      if (seen) {
        const fresh = list.filter((c) => !seen.has(c.sha));
        for (const c of fresh.reverse()) { await showEdit(c); renderTimeline(list); }
      } else {
        renderTimeline(list);
      }
      seen = new Set([...(seen || []), ...list.map((c) => c.sha)]);

      const running = !!(agentInfo && agentInfo.running);
      if (running && !wasRunning) await cursorEnter();
      if (!running && wasRunning) await cursorExit();
      if (running) work(true);
      wasRunning = running;
      renderStatus();
    }
    await sleep(15000 + Math.random() * 5000);
  }
}

/* ── hero ASCII shader: flowing char field on a green→blue gradient ─ */
export function startAscii(cv) {
  const ctx = cv.getContext('2d');
  const RAMP = ' ..::--=+*#%@';
  const CELL = 15;
  let cols, rows, t = 0, running = false;
  const resize = () => {
    cv.width = cv.offsetWidth; cv.height = cv.offsetHeight;
    cols = Math.ceil(cv.width / CELL); rows = Math.ceil(cv.height / CELL);
    ctx.font = '12px ui-monospace, monospace';
  };
  const G = [63, 224, 129], B = [47, 111, 224];
  const frame = () => {
    ctx.clearRect(0, 0, cv.width, cv.height);
    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < cols; x++) {
        const n = Math.sin(x * .19 + t) + Math.cos(y * .23 - t * .7) + Math.sin((x + y) * .11 + t * .5);
        const v = (n + 3) / 6;                       // 0..1
        const ch = RAMP[Math.floor(v * (RAMP.length - 1))];
        if (ch === ' ') continue;
        const m = Math.min(1, Math.max(0, x / cols * .6 + (1 - y / rows) * .4 + (v - .5) * .3));
        const c = G.map((g, i) => Math.round(g * m + B[i] * (1 - m)));
        ctx.fillStyle = `rgba(${c[0]},${c[1]},${c[2]},${(.04 + v * .14).toFixed(3)})`;
        ctx.fillText(ch, x * CELL, y * CELL + 12);
      }
    }
    t += .016;
    if (running) setTimeout(() => requestAnimationFrame(frame), 50);
  };
  resize(); addEventListener('resize', resize);
  if (reduced) { frame(); cv.classList.add('on'); return; }
  new IntersectionObserver(([e]) => {
    const vis = e.isIntersecting;
    if (vis && !running) { running = true; frame(); }
    if (!vis) running = false;
  }).observe(cv.parentElement);
  running = true; frame(); cv.classList.add('on');
}

/* ── boot: intro build plays once per browser; status tick + watch ── */
export function boot() {
  wireDownloads();
  setInterval(renderStatus, 1000);

  const seenIntro = (() => { try { return localStorage.getItem('wb_intro') === '1'; } catch { return false; } })();
  const markIntro = () => { try { localStorage.setItem('wb_intro', '1'); } catch { /* private mode */ } };

  if (reduced || seenIntro) {
    revealHome();
    if (matchMedia('(min-width: 961px)').matches) openPanel();
    else document.body.classList.add('panel-was-open');
  } else {
    build().then(markIntro);
  }
  watch();
}

// Reveal the homepage in its FINAL (post-intro) state. Home's nodes are
// recreated on every route return — the intro only ever plays once, so every
// remount must reveal instantly or the page comes back blank. Idempotent;
// Home.svelte calls this on mount whenever the intro has already been seen.
export function revealHome() {
  const seen = reduced || (() => { try { return localStorage.getItem('wb_intro') === '1'; } catch { return true; } })();
  if (!seen) return;                       // first visit: build() owns the reveal
  document.querySelectorAll('.blk').forEach((b) => b.classList.add('on'));
  if (refs.h1text && !refs.h1text.textContent) refs.h1text.textContent = H1;
  if (refs.cursor && !following) refs.cursor.style.opacity = '0';
}
