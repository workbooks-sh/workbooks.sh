<script>
  import { theme, toggleTheme } from "../lib/theme.svelte.js";
  import Button from "../lib/Button.svelte";
</script>
<header class="nav">
  <a class="brand" href="/">
    <svg viewBox="0 0 257 206" fill="none" aria-label="Workbooks"><path d="M0 206V0.00231147H69.1194V76L126.393 0L168.946 0.00231147V76L223.295 0L257 0.00231147V183C257 195.703 246.703 206 234 206H116.27L112.626 140.5L41.5 206H0Z" fill="currentColor"/></svg>
    <span>Workbooks</span>
  </a>
  <nav>
    <a href="#what">what</a><a href="#proof">how</a><a href="#make">make</a><a href="/docs">docs</a>
    <button class="tt" onclick={toggleTheme}><span class="dot"></span>{theme.mode === "dark" ? "light" : "dark"}</button>
    <Button variant="ink" sm href="#get">Download</Button>
  </nav>
</header>
<style>
  .nav{position:sticky;top:0;z-index:50;display:flex;align-items:center;justify-content:space-between;
    padding:.85rem var(--edge);background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--hair)}
  .brand{display:flex;align-items:center;gap:.6rem;font-family:var(--serif);font-weight:600;font-size:1.3rem;letter-spacing:-.02em}
  .brand svg{height:20px}
  nav{display:flex;align-items:center;gap:1.3rem}
  nav>a{font-family:var(--mono);font-size:.82rem;color:var(--ink2)} nav>a:hover{color:var(--ink)}
  @media(max-width:720px){nav>a{display:none}}
  .tt{display:inline-flex;align-items:center;gap:.5rem;cursor:pointer;border:0;font-family:var(--mono);font-size:.72rem;
    color:var(--ink2);background:var(--bg2);padding:.42rem .75rem;border-radius:999px}
  .tt .dot{width:9px;height:9px;border-radius:50%;background:var(--ink)} :global([data-theme="dark"]) .tt .dot{background:var(--green)}
</style>
