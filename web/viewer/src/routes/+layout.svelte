<script lang="ts">
  import "../app.css";
  import { page } from "$app/state";
  let { children } = $props();

  // Live URL runner pages at /r/<slug> are full-bleed — no top bar,
  // no footer, no padding. Everything else (landing, /w/<rid>) keeps
  // the standard chrome. SvelteKit's +page@.svelte reset proved
  // unreliable in 2.61 for dynamic-param routes, so we gate at the
  // layout level instead.
  const bare = $derived(page.url.pathname.startsWith("/r/"));
</script>

{#if bare}
  {@render children?.()}
{:else}
  <header class="topbar">
    <a href="/" class="brand">
      <span class="mark">W</span>
      <span class="name">Workbooks</span>
    </a>
    <nav class="nav">
      <a href="https://workbooks.sh" class="nav-link">About</a>
      <a href="https://github.com/workbooks-sh" class="nav-link">GitHub</a>
    </nav>
  </header>

  <main>
    {@render children?.()}
  </main>

  <footer class="foot">
    <span>workbooks.sh — peer-to-peer workbook sharing on Radicle</span>
  </footer>
{/if}

<style>
  .topbar {
    display: flex;
    align-items: center;
    gap: 24px;
    padding: 14px 28px;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface);
  }
  .brand {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    text-decoration: none;
    color: var(--color-fg);
    font-weight: 700;
  }
  .mark {
    display: inline-grid;
    place-items: center;
    width: 22px;
    height: 22px;
    border-radius: 6px;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 0.78rem;
    font-weight: 700;
  }
  .name { font-size: 0.95rem; }
  .nav {
    margin-left: auto;
    display: flex;
    gap: 18px;
  }
  .nav-link {
    color: var(--color-fg-muted);
    text-decoration: none;
    font-size: 0.85rem;
  }
  .nav-link:hover { color: var(--color-fg); }
  main {
    min-height: calc(100vh - 110px);
    padding: 40px 28px;
  }
  .foot {
    padding: 16px 28px;
    border-top: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    text-align: center;
  }
</style>
