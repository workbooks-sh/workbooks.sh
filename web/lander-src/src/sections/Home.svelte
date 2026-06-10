<script>
  // The homepage content region. This is the DEFAULT content of #route — the
  // sections that were previously inlined in App.svelte. Extracted so the shell
  // (nav/Cursor/Viewer/Panel) can stay mounted while #route swaps between home,
  // the blog index, and a post. The intro build choreography targets these
  // nodes (#b-*, #grown) and runs once on first load of `/`; navigating back
  // here from a post does NOT replay it (the nodes are already built).
  import Hero from './Hero.svelte';
  import Layers from './Layers.svelte';
  import Who from './Who.svelte';
  import Get from './Get.svelte';
  import Grown from './Grown.svelte';
  import Wmark from '../lib/Wmark.svelte';
</script>

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
