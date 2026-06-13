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
      <svg viewBox="0 0 113.444 65.6002" fill="none"><path d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z" fill="currentColor"/></svg>
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

/* ── the inspect panel, app-wide ──────────────────────────────────
   Every page carries the timeline as a layout component. Subpages get
   a compact version: closed by default behind the chip; opens as a
   right panel (desktop) / bottom sheet (mobile). The homepage ships
   its own richer panel and skips this (id #timeline present). */
(() => {
  if (document.querySelector('#timeline')) return;

  const css = `
  .wbp { position: fixed; top: 0; right: 0; bottom: 0; width: 332px; z-index: 50;
    display: flex; flex-direction: column; gap: 10px; padding: 14px;
    background: #0c0d10; border-left: 1px solid #262a32;
    font-family: "Geist Mono", ui-monospace, monospace;
    transform: translateX(102%); transition: transform .5s cubic-bezier(.3,.8,.3,1); }
  body.wbp-open .wbp { transform: none; }
  .wbp .c { background: #14161b; border: 1px solid #262a32; border-radius: 12px; padding: 13px 16px; }
  .wbp .hd { display: flex; align-items: center; justify-content: space-between; gap: 10px;
    font: 500 12px/1 "Geist Mono", monospace; color: #eceef2; }
  .wbp .hd a { color: #565b64; text-decoration: none; font-size: 10.5px; }
  .wbp .hd a:hover { color: #eceef2; }
  .wbp .hd .x { cursor: pointer; background: none; border: 0; color: #565b64; font-size: 14px; }
  .wbp .st { margin-top: 8px; display: flex; justify-content: space-between;
    font: 400 11px/1 "Geist Mono", monospace; color: #8b909a; }
  .wbp .st .dream { color: #b48cff; text-decoration: none; }
  .wbp .tl { flex: 1; overflow-y: auto; padding: 14px 16px; scrollbar-width: thin; }
  .wbp .n { position: relative; padding: 0 0 16px 24px; }
  .wbp .n::before { content: ""; position: absolute; left: 5px; top: 18px; bottom: 0; width: 1px; background: #262a32; }
  .wbp .n:last-child::before { display: none; }
  .wbp .n .i { position: absolute; left: 0; top: 2px; width: 12px; height: 12px; }
  .wbp .n .i svg { display: block; width: 100%; height: 100%; }
  .wbp .n .m { font: 400 11px/1.45 "Geist Mono", monospace; color: #eceef2; overflow-wrap: anywhere; }
  .wbp .n.h .m { color: #8b909a; }
  .wbp .n .w { font: 400 9.5px/1 "Geist Mono", monospace; color: #565b64; margin-top: 3px; display: block; }
  .wbp .n .w a { color: inherit; text-decoration: none; border-bottom: 1px dotted #262a32; }
  .wbpeek { position: fixed; right: 18px; bottom: 18px; z-index: 49;
    display: flex; align-items: center; gap: 8px; cursor: pointer;
    background: #14161b; color: #8b909a; border: 1px solid #262a32; border-radius: 999px;
    padding: 10px 14px; font: 500 11.5px/1 "Geist Mono", monospace;
    box-shadow: 0 12px 32px -16px rgba(0,0,0,.8); }
  .wbpeek:hover { color: #eceef2; }
  .wbpeek .d { width: 7px; height: 7px; border-radius: 50%; background: #b48cff;
    animation: wbbreathe 3.4s ease-in-out infinite; }
  .wbpeek.live .d { background: #3fe081; animation: none; }
  @keyframes wbbreathe { 50% { opacity: .35; } }
  body.wbp-open .wbpeek { display: none; }
  @media (max-width: 960px) {
    .wbp { left: 0; width: 100%; top: 16vh; border-radius: 18px 18px 0 0; border-left: 0;
      border-top: 1px solid #262a32; transform: translateY(105%); }
    body.wbp-open .wbp { transform: none; }
  }`;
  const st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);

  const ICONS = {
    person: '<svg viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="4.4" r="3.1"/><path d="M8 8.6c-3.4 0-6.1 2.1-6.1 4.8 0 .4.3.8.8.8h10.6c.5 0 .8-.4.8-.8 0-2.7-2.7-4.8-6.1-4.8Z"/></svg>',
    robot: '<svg viewBox="0 0 16 16" fill="currentColor"><path fill-rule="evenodd" d="M8 .8c.5 0 .9.4.9.9v1.5h2.6A2.5 2.5 0 0 1 14 5.7v3.6a2.5 2.5 0 0 1-2.5 2.5h-7A2.5 2.5 0 0 1 2 9.3V5.7a2.5 2.5 0 0 1 2.5-2.5h2.6V1.7c0-.5.4-.9.9-.9ZM5.7 6.1a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6Zm4.6 0a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6Z"/><path d="M4.6 13h6.8c.6 0 1 .4 1 1v.9H3.6V14c0-.6.4-1 1-1Z"/></svg>'
  };
  const TYPES = { add: '#3fe081', blog: '#5aa7ff', tweet: '#5aa7ff', rem: '#b48cff', audit: '#e0b34a', plan: '#565b64', planning: '#565b64', keeper: '#565b64' };
  const classify = c => {
    const m = /^([a-z]+):/i.exec(c.msg); const tag = m && m[1].toLowerCase();
    if (tag && TYPES[tag]) return { who: 'waldo', color: TYPES[tag] };
    if ((c.author || '').toLowerCase() === 'waldo') return { who: 'waldo', color: '#3fe081' };
    return { who: 'human', color: '#565b64' };
  };
  const rel = ts => { if (!ts) return ''; const s = Math.floor(Date.now()/1000 - ts);
    return s < 60 ? s + 's' : s < 3600 ? Math.floor(s/60) + 'm' : s < 86400 ? Math.floor(s/3600) + 'h' : Math.floor(s/86400) + 'd'; };

  const panel = document.createElement('aside');
  panel.className = 'wbp';
  panel.innerHTML = `
    <div class="c hd-c">
      <div class="hd"><span>timeline</span><span><a href="/">full view →</a> <button class="x" aria-label="close">×</button></span></div>
      <div class="st"><span id="wbpState">…</span><a class="dream" href="/rem/">dreams →</a></div>
    </div>
    <div class="c tl"><div id="wbpList"></div></div>`;
  document.body.appendChild(panel);

  const peek = document.createElement('button');
  peek.className = 'wbpeek';
  peek.innerHTML = '<span class="d"></span>timeline';
  document.body.appendChild(peek);

  peek.onclick = () => document.body.classList.add('wbp-open');
  panel.querySelector('.x').onclick = () => document.body.classList.remove('wbp-open');

  async function refresh() {
    try {
      const res = await fetch('/_changes', { signal: AbortSignal.timeout(8000) });
      if (!res.ok) return;
      const { changes, agent } = await res.json();
      const running = !!(agent && agent.running);
      peek.classList.toggle('live', running);
      document.querySelector('#wbpState').textContent = running ? 'waldo working' : 'waldo dreaming';
      document.querySelector('#wbpList').innerHTML = (changes || []).slice(0, 20).map(c => {
        const k = classify(c);
        return `<div class="n ${k.who === 'human' ? 'h' : ''}">
          <span class="i" style="color:${k.color}">${ICONS[k.who === 'human' ? 'person' : 'robot']}</span>
          <span class="m">${c.msg.replace(/</g, '&lt;')}</span>
          <span class="w"><a href="https://github.com/workbooks-sh/living-lander/commit/${c.sha}" target="_blank" rel="noopener">${c.sha}</a> · ${rel(c.ts)}</span>
        </div>`;
      }).join('');
    } catch { /* offline */ }
  }
  refresh();
  setInterval(refresh, 30000);
})();
