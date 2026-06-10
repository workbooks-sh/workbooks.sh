/* The lander's behavior engine — a single module-level singleton that
   mirrors the original hand-written IIFE. Components register their DOM
   nodes (cursor, panel pieces) here; the engine drives them imperatively,
   exactly as the source did via document.querySelector. Keeping one engine
   preserves the shared closures (cursor ⇄ build ⇄ watch ⇄ follow) that the
   choreography depends on. */

const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const sleep = (ms) => new Promise((r) => setTimeout(r, reduced ? 0 : ms));

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
// known never-frameable hosts (X-Frame-Options/CSP deny) — skip straight to the card
const NO_FRAME = /(^|\.)(github\.com|google\.com|twitter\.com|x\.com|youtube\.com|reddit\.com)$/i;

function viewerHead(verb, target, thought) {
  if (refs.viewerVerb) refs.viewerVerb.textContent = `${verb} ${trimWords(target, 38)}`;
  if (refs.viewerThought) refs.viewerThought.textContent = trimWords(thought || '', 60);
}

function urlCard(u) {
  // styled fallback when an iframe won't load: favicon + domain + url + "reading"
  let host = u; try { host = new URL(u).host; } catch { /* keep raw */ }
  const fav = `https://www.google.com/s2/favicons?domain=${encodeURIComponent(host)}&sz=64`;
  return `<div class="vcard">
    <img class="vfav" src="${escH(fav)}" alt="" width="32" height="32"
         onerror="this.style.visibility='hidden'">
    <div class="vdom">${escH(host)}</div>
    <div class="vurl">${escH(trimWords(u, 90))}</div>
    <div class="vtag">reading</div>
  </div>`;
}

function showUrl(u) {
  const body = refs.viewerBody;
  let host = ''; try { host = new URL(u).host; } catch { /* unframeable below */ }
  if (!host || NO_FRAME.test(host)) { body.innerHTML = urlCard(u); return; }
  // try an iframe; if it errors or never loads, fall back to the card
  body.innerHTML =
    `<iframe class="vframe" sandbox="allow-scripts allow-same-origin"
       referrerpolicy="no-referrer" src="${escH(u)}"></iframe>`;
  const fr = body.querySelector('iframe');
  let settled = false;
  const fail = () => { if (settled) return; settled = true; body.innerHTML = urlCard(u); };
  fr.addEventListener('error', fail);
  fr.addEventListener('load', () => { settled = true; });    // it framed — keep it
  setTimeout(fail, 3200);                                     // many denials are silent
}

// code → numbered monospace lines; .org headings (lines starting with *) tinted
const codeHtml = (text, isOrg) => {
  const lines = text.split('\n');
  return `<pre class="vcode"><table>${lines.map((ln, i) => {
    const head = isOrg && /^\*+\s/.test(ln);
    return `<tr><td class="vln">${i + 1}</td><td class="vsrc${head ? ' vorg' : ''}">${escH(ln) || ' '}</td></tr>`;
  }).join('')}</table></pre>`;
};

async function showFile(path, verb) {
  const body = refs.viewerBody;
  body.innerHTML = `<div class="vload">${escH(path)}</div>`;
  let res = null;
  try { res = await fetch(RAW + path, { signal: AbortSignal.timeout(7000) }); }
  catch { /* offline → 404 card below */ }
  if (!res || !res.ok) {
    // not yet committed: be honest — it's a draft only Waldo can see right now
    body.innerHTML = `<div class="vcard">
      <div class="vdom">${escH(path)}</div>
      <div class="vurl">${escH(verb)} ${escH(path.split('/').pop())} — first draft, not yet committed</div>
      <div class="vtag">${escH(verb)}</div>
    </div>`;
    return;
  }
  body.innerHTML = codeHtml(await res.text(), /\.org$/.test(path));
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
  const key = t.url ? 'u:' + t.url : 'f:' + t.file;
  if (key === viewerKey && win.classList.contains('open')) {
    viewerHead(t.verb, t.url || t.file, t.thought);      // same target, refresh header only
    return true;
  }
  viewerKey = key;
  win.classList.add('open');
  viewerHead(t.verb, t.url || t.file, t.thought);
  if (t.url) showUrl(t.url); else showFile(t.file, t.verb);
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

/* a fresh add: commit may mean a new section — pull it into the open page */
async function refreshGrown() {
  try {
    const res = await fetch('/', { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return null;
    const doc = new DOMParser().parseFromString(await res.text(), 'text/html');
    const next = doc.querySelector('#grown');
    const here = document.querySelector('#grown');
    if (next && next.innerHTML.trim() !== here.innerHTML.trim()) {
      const firstNew = await mergeGrown(here, next);
      const secs = document.querySelectorAll('#grown section');
      return firstNew || secs[0] || null;     // newest lands first (agent prepends)
    }
  } catch { /* same-origin only — fine on localhost */ }
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
  // a grown section: map to its on-page element when rendered; else the file view
  const grown = /src\/sections\/grown\/(\d{2}-[\w-]+)\.svelte/.exec(t);
  if (grown) {
    const el = document.querySelector(`[data-grown="${grown[1]}"]`);
    if (el) return { el };
    return { file: `src/sections/grown/${grown[1]}.svelte`, verb };
  }
  // any other tracked source file → the viewer reads the committed bytes
  const file = /((?:src\/[\w./-]+\.svelte)|(?:(?:strategy|skills|rem)\/[\w./-]+\.org)|plan\.org|(?:blog\/[\w-]+\.html))/.exec(t);
  if (file) {
    const f = file[1];
    if (f.startsWith('blog/')) {
      // a blog page: redirect only when following + not already there; else view it
      const page = '/' + f;
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
  if (url) return { url: url[1], verb };
  // nothing we can place — hold. (Do NOT fall back to the headline.)
  return {};
};
// the follow button reflects engine state: a toggle, not a one-shot. The panel
// re-reads this on its status tick.
const setFollowBtn = (on) => {
  const b = document.querySelector('#followBtn');
  if (!b) return;
  b.classList.toggle('on', on);
  b.textContent = on ? 'following ✓ — click to stop' : 'follow along — it\'s working now';
};
// last resolved target — the cursor only MOVES when this changes, so repeated
// same-target steps don't make it twitch around the page.
let lastKey = null;
const targetKey = (t) =>
  t.page ? 'p:' + t.page : t.url ? 'u:' + t.url : t.file ? 'f:' + t.file :
  t.git ? 'g:' + (t.el ? [...t.el.parentNode.children].indexOf(t.el) : '?') :
  t.el ? 'e:' + (t.el.dataset.grown || t.el.id || t.el.tagName) : '';

async function stopFollow() {
  if (!following) return;
  following = false;                 // ends the poll loop on its next check
  setFollowBtn(false);
  closeViewer();
  think(null); work(false);
  await cursorExit();
  lastKey = null;
}

async function follow() {
  following = true;
  setFollowBtn(true);
  document.querySelector('#followBtn').hidden = false;
  await cursorEnter();
  think('let me show you what I\'m doing');
  work(true);
  let misses = 0;
  while (following) {
    const act = await fetchActivity();
    if (!act && ++misses === 3) think('(its live feed is warming up — changes still land below)');
    if (act) {
      misses = 0;
      if (!act.agent || !act.agent.running) {       // run ended → auto-stop
        think('done — shipping it');
        await sleep(1600);
        await stopFollow();
        break;
      }
      // header thought always tracks; bubble only when the cursor is out (not absorbed)
      if (act.thought && !absorbed) think(act.thought);
      if (act.thought && isViewerOpen()) viewerHead(
        refs.viewerVerb?.textContent?.split(' ')[0] || 'reading',
        viewerKey ? viewerKey.slice(2) : '', act.thought);

      const last = (act.steps || [])[act.steps.length - 1];
      if (last && last.ts > lastStepTs) {
        lastStepTs = last.ts;
        const t = stepTarget(last);
        t.thought = act.thought;
        const key = targetKey(t);
        if (!key || key === lastKey) { await sleep(2500); continue; }  // unchanged → hold
        lastKey = key;

        if (t.page) {                                // another lander page — go there
          think('working over here — come on');
          await sleep(1400);
          if (following) location.assign(t.page);
          return;
        }
        if (t.url || t.file) {                        // off-page → the viewer window
          if (openViewer(t)) { if (!absorbed) await absorbCursor(); }
          else { refs.cursor.style.opacity = '0'; }   // ≤640px: no viewer, just hide
        } else if (t.git && !document.body.classList.contains('panel-open')) {
          if (isViewerOpen()) { await popCursor(null); closeViewer(); }
          refs.cursor.style.opacity = '0';            // reading history out of sight
        } else if (t.el) {                            // on-page → cursor returns here
          if (isViewerOpen()) { closeViewer(); await popCursor(t.el); }
          else {
            refs.cursor.style.opacity = '1';
            t.el.scrollIntoView?.({ behavior: 'smooth', block: 'center' });
            await sleep(350);
            await moveTo(t.el);
          }
          t.el.classList.add('touch');
          setTimeout(() => t.el.classList.remove('touch'), 1600);
        }
      }
    }
    await sleep(2500);
  }
}
// the button toggles: start when idle, stop when following
export const toggleFollow = () => { following ? stopFollow() : follow(); };

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
    document.querySelectorAll('.blk').forEach((b) => b.classList.add('on'));
    refs.h1text.textContent = H1;
    if (matchMedia('(min-width: 961px)').matches) openPanel();
    else document.body.classList.add('panel-was-open');
  } else {
    build().then(markIntro);
  }
  watch();
}
