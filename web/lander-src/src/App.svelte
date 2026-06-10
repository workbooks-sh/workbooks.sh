<script>
  // The persistent shell. nav, Cursor, Viewer, and Panel mount ONCE and never
  // unmount — only #route's content swaps as the router changes. This is the
  // whole point: one shell (the homepage's full panel + cursor + follow session)
  // everywhere, so navigating to a blog post never drops the visitor out of the
  // real UI onto a standalone page (where site.js's compact panel used to take
  // over). See lib/router.svelte.js.
  import Cursor from './lib/Cursor.svelte';
  import Panel from './lib/Panel.svelte';
  import Viewer from './lib/Viewer.svelte';
  import Wmark from './lib/Wmark.svelte';
  import Home from './sections/Home.svelte';
  import BlogIndex from './sections/BlogIndex.svelte';
  import BlogPost from './sections/BlogPost.svelte';
  import { boot } from './lib/stores.js';
  import { route, startRouter } from './lib/router.svelte.js';

  startRouter();
  const r = $derived(route());

  // boot runs once the whole page is in the DOM — the build choreography needs
  // every #b-* node present and every ref registered. The intro itself only
  // plays on first load of `/` (guarded inside boot via wb_intro + the home
  // route); the watch/follow loops run regardless of route.
  $effect(() => { boot(); });
</script>

<!-- ── PERSISTENT SHELL — mounted once, outside #route, never re-rendered ── -->

<!-- agent cursor -->
<Cursor />

<!-- follow-mode off-page window: what Waldo is reading when his step is off-page -->
<Viewer />

<!-- floating nav -->
<nav class="nav blk" id="b-nav" aria-label="Primary">
  <a class="glyph" href="/" aria-label="Workbooks home"><Wmark aria-label="Workbooks" role="img" /></a>
  <a class="word" href="/">workbooks</a>
  <a href="/blog">blog</a>
  <a href="https://github.com/workbooks-sh/workbooks.sh">github</a>
  <a class="cta" href="https://github.com/workbooks-sh/workbooks.sh/releases/tag/desktop-v0.1.0" id="navDl">download</a>
</nav>

<!-- ── CONTENT REGION — the only thing navigation swaps ── -->
<div class="content">
  <main id="route">
    {#if r.name === 'post'}
      {#key r.slug}<BlogPost slug={r.slug} />{/key}
    {:else if r.name === 'blog'}
      <BlogIndex />
    {:else}
      <Home />
    {/if}
  </main>
</div>

<!-- fixed right panel: the live timeline -->
<Panel />
