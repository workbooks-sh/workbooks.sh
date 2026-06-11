// The runtime CMS client (DESIGN.md §7). Loads the ordered manifest
// (content/stories.json) once, then lazily fetches + renders each story's .org
// body with the vendored orgitorial renderer. No build step touches content —
// stories are data, fetched at runtime, so the crew can publish by writing a
// row + an .org file (the future runtime path).

import { render } from '../vendor/orgitorial.js';

// base: vite is configured base:'./' so a dumb static server can host dist/.
// import.meta.env.BASE_URL gives us the right prefix in dev ('/') and prod ('./').
const BASE = import.meta.env.BASE_URL || '/';
function url(p) { return BASE.replace(/\/$/, '') + '/' + p.replace(/^\//, ''); }

let _manifest = $state(null);          // null until loaded
let _loading = false;
const _bodies = new Map();             // slug → rendered HTML string (cache)
const _imgs = new Map();               // path → resolved src (data-URI in workbook mode)

export function manifest() { return _manifest; }

// Resolve a banner/image path to a usable <img src>. In WORKBOOK MODE the
// bundler inlines each image as <script type="x-image" data-path data-mime>{b64}>
// (bundle-workbook.mjs) — we turn that into a data-URI so the single-file
// artifact is fully self-contained (no fetch). On a normal server, just prefix
// the BASE so the static file resolves. Missing → return the plain url; the
// <img onerror> hides it (DESIGN §4.5 note 3). Cached per path.
export function imageUrl(path) {
  if (!path) return null;
  if (_imgs.has(path)) return _imgs.get(path);
  let resolved = url(path);
  if (typeof document !== 'undefined') {
    const inline = document.querySelector(`script[type="x-image"][data-path="${path}"]`);
    if (inline) {
      const mime = inline.getAttribute('data-mime') || 'image/png';
      resolved = `data:${mime};base64,${inline.textContent.trim()}`;
    }
  }
  _imgs.set(path, resolved);
  return resolved;
}

// Kick the manifest fetch once. Idempotent. Components read manifest() reactively.
export function loadManifest() {
  if (_manifest || _loading) return;
  // WORKBOOK MODE: a bundled single-file artifact carries the manifest inline
  // (<script type="application/json" id="wb-stories">) — no server, no fetch.
  const inline = typeof document !== 'undefined' && document.getElementById('wb-stories');
  if (inline) {
    try { _manifest = JSON.parse(inline.textContent).stories || []; return; } catch { /* fall through */ }
  }
  _loading = true;
  fetch(url('content/stories.json'))
    .then((r) => r.json())
    .then((j) => { _manifest = j.stories || []; })
    .catch(() => { _manifest = []; })
    .finally(() => { _loading = false; });
}

export function storyBySlug(slug) {
  return (_manifest || []).find((s) => s.slug === slug) || null;
}

// Newest published story → the WireLead on the front page (DESIGN.md §3 build
// note). Manifest is in published order; "newest published" = first non-live
// row by date. We keep it simple: first row whose status==='published'.
export function newestPublished() {
  return (_manifest || []).find((s) => s.status === 'published') || null;
}

// All bites for the stack: everything except the WireLead, in manifest order.
// The live story stays in the stack (gets the live treatment) AND is newest, so
// it never collides with the published WireLead.
export function stackBites(leadSlug) {
  return (_manifest || []).filter((s) => s.slug !== leadSlug);
}

export function bySection(section) {
  const sec = String(section || '').toUpperCase();
  return (_manifest || []).filter((s) => s.section.toUpperCase() === sec);
}

// "more from <section>" — up to n other stories in the same section.
export function moreFrom(section, excludeSlug, n = 3) {
  return bySection(section).filter((s) => s.slug !== excludeSlug).slice(0, n);
}

// Fetch + render a story body to HTML (cached). Returns a Promise<string>.
// Orgitorial renders the article; we strip its own <header> (header:false) since
// the bit.ml Story component renders the headline/dek/byline natively in the
// serif voice — the org body is just the prose.
export async function storyBody(slug) {
  if (_bodies.has(slug)) return _bodies.get(slug);
  const row = storyBySlug(slug);
  if (!row) return '';
  // WORKBOOK MODE: org bodies travel inline as <script type="text/org" data-slug>.
  const inline = typeof document !== 'undefined' &&
    document.querySelector(`script[type="text/org"][data-slug="${slug}"]`);
  const org = inline ? inline.textContent
    : await fetch(url(row.file)).then((r) => r.text());
  const html = render(org, { header: false });
  _bodies.set(slug, html);
  return html;
}
