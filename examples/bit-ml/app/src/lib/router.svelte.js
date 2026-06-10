/* The client-side router — keystone of the persistent-shell SPA (mirrors the
   living-lander's lib/router.svelte.js). The shell (Masthead + CrewPanel +
   Footer + the theme toggle) mounts ONCE and never unmounts; navigation only
   swaps the CONTENT REGION (#route). A full document load would tear the shell
   down — so we intercept internal clicks, drive History API, and flip a rune.

   DESIGN.md §5: zero fades between routes (instant swap), no redirects ever.

   Routes:
     /                 → front page
     /s/<section>      → section front (ai | markets | chips | policy)
     /story/<slug>     → story page
     /design           → the living styleguide (the old specimen)

   No deps: History API + one reactive rune. App.svelte reads `route()` to pick
   which view to render inside #route; the shell lives outside #route. */

let _route = $state(parse(location.pathname));
export function route() { return _route; }

// Parse a pathname into { name, ... }. Bare hash anchors (#stack) are in-page
// links — the browser handles them; they don't change the route.
function parse(pathname) {
  const p = (pathname || '/').replace(/\/+$/, '') || '/';
  if (p === '/' || p === '') return { name: 'home' };
  if (p === '/design') return { name: 'design' };
  let m = /^\/s\/([\w-]+)$/.exec(p);
  if (m) return { name: 'section', section: m[1].toLowerCase() };
  m = /^\/story\/([\w-]+)$/.exec(p);
  if (m) return { name: 'story', slug: m[1] };
  // anything we don't own → let the browser load it (a real navigation)
  return { name: 'external', path: p };
}

// Navigate in-shell: push history + flip the rune. Scroll to top — every push
// is a fresh page conceptually. Instant: no smooth-scroll (§5 fast or absent).
export function push(path) {
  const next = parse(path);
  if (next.name === 'external') { location.assign(path); return; }
  // file:// (an opened workbook) forbids pushState — navigation still works
  // in-memory, the URL bar just stays put.
  try { if (path !== location.pathname) history.pushState({}, '', path); } catch { /* workbook mode */ }
  _route = next;
  dispatchEvent(new CustomEvent('wb:route'));
  scrollTo({ top: 0, behavior: 'auto' });
}

// Should this anchor be intercepted into an in-shell navigation? Only same-origin
// links to routes we own. External hosts, target=_blank, modified clicks,
// downloads, and bare hash anchors fall through to the browser.
export function shouldIntercept(a, ev) {
  if (!a || ev.defaultPrevented) return false;
  if (ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return false;
  if (a.target && a.target !== '' && a.target !== '_self') return false;
  if (a.hasAttribute('download')) return false;
  const href = a.getAttribute('href') || '';
  if (!href || href.startsWith('#')) return false;            // in-page anchor
  let url; try { url = new URL(href, location.href); } catch { return false; }
  if (url.origin !== location.origin) return false;           // external
  if (url.pathname === location.pathname && url.hash) return false; // same page + hash
  return parse(url.pathname).name !== 'external';
}

// Wire global click interception + back/forward. Called once from the shell.
export function startRouter() {
  addEventListener('click', (ev) => {
    const a = ev.target.closest && ev.target.closest('a[href]');
    if (shouldIntercept(a, ev)) { ev.preventDefault(); push(new URL(a.href).pathname); }
  });
  addEventListener('popstate', () => { _route = parse(location.pathname); dispatchEvent(new CustomEvent('wb:route')); });
}
