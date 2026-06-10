/* The client-side router — the keystone of the persistent-shell SPA.

   Why this exists: the shell (nav + Cursor + Viewer + Panel + the live follow
   session) must NEVER unmount. A full document load tears all of that down and
   drops the visitor onto a standalone page where the compact site.js panel takes
   over — a different UI with no cursor, no follow, no viewer. So navigation can
   only ever swap the CONTENT REGION (#route); the shell stays mounted.

   No deps: History API + one reactive rune. App.svelte reads `current` to pick
   which content view to render inside #route; everything else (the shell) lives
   outside #route and is immune to route changes. */

// the live route, as a rune so App.svelte re-renders only #route when it changes
let _route = $state(parse(location.pathname));
export function route() { return _route; }

// Parse a pathname into { name, slug }. Hash anchors (#timeline) are homepage
// in-page links — they don't change the route; the browser handles the scroll.
function parse(pathname) {
  const p = (pathname || '/').replace(/\/+$/, '') || '/';
  if (p === '/' || p === '') return { name: 'home', slug: null };
  if (p === '/blog') return { name: 'blog', slug: null };
  const m = /^\/blog\/([\w-]+)(?:\.html)?$/.exec(p);
  if (m) return { name: 'post', slug: m[1] };
  // anything else we don't own as an in-shell view → let the browser load it
  return { name: 'external', slug: p };
}

// Navigate in-shell: push history + flip the rune. Scroll to top because every
// route is a fresh document conceptually (home keeps its scroll only on first
// boot; a deliberate push always starts at the top, like a real page load).
export function push(path) {
  const next = parse(path);
  if (next.name === 'external') { location.assign(path); return; }
  if (path !== location.pathname) history.pushState({}, '', path);
  _route = next;
  // the engine listens: cursor placement is per-route (a target on the old
  // route's DOM means nothing on the new one).
  dispatchEvent(new CustomEvent('wb:route'));
  scrollTo({ top: 0, behavior: 'instant' in scrollTo ? 'instant' : 'auto' });
}

// Should this anchor be intercepted into an in-shell navigation? Only same-origin
// links to routes we own. External hosts (github, download), explicit new-tab
// (target=_blank), modified clicks, downloads, and bare hash anchors fall through
// to the browser so nothing the shell can't host stays trapped in the shell.
export function shouldIntercept(a, ev) {
  if (!a || ev.defaultPrevented) return false;
  if (ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return false;
  if (a.target && a.target !== '' && a.target !== '_self') return false;
  if (a.hasAttribute('download')) return false;
  const href = a.getAttribute('href') || '';
  if (!href || href.startsWith('#')) return false;          // in-page anchor
  let url; try { url = new URL(href, location.href); } catch { return false; }
  if (url.origin !== location.origin) return false;         // external
  if (url.pathname === location.pathname && url.hash) return false; // same page + hash
  return parse(url.pathname).name !== 'external';
}

// Wire global click interception + back/forward. Called once from the shell.
export function startRouter() {
  addEventListener('click', (ev) => {
    const a = ev.target.closest && ev.target.closest('a[href]');
    if (shouldIntercept(a, ev)) { ev.preventDefault(); push(new URL(a.href).pathname); }
  });
  // back/forward: re-parse the (now-current) location — no pushState, just sync
  addEventListener('popstate', () => { _route = parse(location.pathname); dispatchEvent(new CustomEvent('wb:route')); });
}
