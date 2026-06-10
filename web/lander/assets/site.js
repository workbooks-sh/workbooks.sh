/* site.js — the one nav, shared by every page on this site.
   Include on any page: <script src="/assets/site.js" defer></script>
   No-ops if the page already carries a .nav (the homepage builds its own). */
(() => {
  if (document.querySelector('.nav')) return;

  // one nav means ONE: any page-local top bar gets replaced, not stacked under
  document.querySelectorAll('body > nav').forEach(el => el.remove());

  const css = `
  .nav{position:fixed;top:18px;left:50%;translate:-50% 0;z-index:40;display:flex;align-items:center;gap:22px;
    padding:9px 10px 9px 14px;background:color-mix(in srgb,#14161b 82%,transparent);border:1px solid #262a32;
    border-radius:999px;backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
    box-shadow:0 12px 32px -16px rgba(0,0,0,.8);font-family:"Geist",system-ui,sans-serif;}
  .nav .glyph{width:22px;height:18px;color:#eceef2;display:block}
  .nav .glyph svg{display:block;width:100%;height:100%}
  .nav .word{font:500 13.5px/1 "Geist",system-ui,sans-serif;color:#eceef2;letter-spacing:.01em;margin-right:4px}
  .nav a{color:#8b909a;text-decoration:none;font:400 13px/1 "Geist",system-ui,sans-serif;transition:color .15s}
  .nav a:hover{color:#eceef2}
  .nav a.word{color:#eceef2}
  .nav .cta{color:#0c0d10;background:#eceef2;border-radius:999px;padding:7px 13px;
    font:500 12.5px/1 "Geist Mono",ui-monospace,monospace;letter-spacing:-.01em}
  .nav .cta:hover{background:#fff;color:#000}
  @media (max-width:640px){.nav{gap:14px}.nav .word{display:none}}`;

  const R = 'https://github.com/workbooks-sh/workbooks.sh/releases/download/desktop-v0.1.0/';
  const ua = navigator.userAgent;
  const dl =
    /Mac/.test(ua) ? R + 'Workbooks_0.1.0_aarch64.dmg' :
    /Win/.test(ua) ? R + 'Workbooks_0.1.0_x64-setup.exe' :
    /Linux/.test(ua) ? R + 'Workbooks_0.1.0_amd64.AppImage' :
    'https://github.com/workbooks-sh/workbooks.sh/releases/tag/desktop-v0.1.0';

  const style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  const nav = document.createElement('nav');
  nav.className = 'nav';
  nav.setAttribute('aria-label', 'Primary');
  nav.innerHTML = `
    <a class="glyph" href="/" aria-label="Workbooks home">
      <svg viewBox="0 0 258 206" fill="none"><path d="M0 206V0.00231147H69.3883V76L126.885 0L169.603 0.00231147V76L224.164 0L258 0.00231147V206H116.723L113.064 140.5L41.6615 206H0Z" fill="currentColor"/></svg>
    </a>
    <a class="word" href="/">workbooks</a>
    <a href="https://github.com/workbooks-sh/workbooks.sh">docs</a>
    <a href="https://github.com/workbooks-sh/workbooks.sh">github</a>
    <a class="cta" href="${dl}">download</a>`;
  document.body.prepend(nav);

  // fixed nav needs breathing room on pages that didn't plan for it
  const pt = parseFloat(getComputedStyle(document.body).paddingTop) || 0;
  if (pt < 72) document.body.style.paddingTop = '84px';
})();
