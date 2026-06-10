<script>
  import Cursor from './lib/Cursor.svelte';
  import Panel from './lib/Panel.svelte';
  import Viewer from './lib/Viewer.svelte';
  import Wmark from './lib/Wmark.svelte';
  import Hero from './sections/Hero.svelte';
  import Layers from './sections/Layers.svelte';
  import Who from './sections/Who.svelte';
  import Get from './sections/Get.svelte';
  import Grown from './sections/Grown.svelte';
  import { boot } from './lib/stores.js';

  // boot runs once the whole page is in the DOM — the build choreography
  // needs every #b-* node present and every ref registered.
  $effect(() => { boot(); });
</script>

<!-- agent cursor -->
<Cursor />

<!-- follow-mode off-page window: what Waldo is reading when his step is off-page -->
<Viewer />

<!-- floating nav -->
<nav class="nav blk" id="b-nav" aria-label="Primary">
  <span class="glyph"><Wmark aria-label="Workbooks" role="img" /></span>
  <span class="word">workbooks</span>
  <a href="https://github.com/workbooks-sh/workbooks.sh">docs</a>
  <a href="https://github.com/workbooks-sh/workbooks.sh">github</a>
  <a class="cta" href="https://github.com/workbooks-sh/workbooks.sh/releases/tag/desktop-v0.1.0" id="navDl">download</a>
</nav>

<div class="content">
  <Hero />
  <Layers />
  <Who />
  <Get />

  <!-- the agent appends new sections here (sections/grown/*.svelte) -->
  <Grown />

  <footer class="foot">
    <div class="inner">
      <span class="glyph"><Wmark /></span>
      <span>workbooks</span>
      <a href="https://github.com/workbooks-sh/workbooks.sh">github</a>
      <a href="https://github.com/workbooks-sh/living-lander">this site's source</a>
      <span class="tail">served live by the workbooks runtime · kept by waldo</span>
    </div>
  </footer>
</div>

<!-- fixed right panel: the live timeline -->
<Panel />
