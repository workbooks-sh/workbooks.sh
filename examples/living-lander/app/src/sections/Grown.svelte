<script>
  // Agent-grown sections are a RUNTIME CMS — no build step. At mount we fetch
  // /content/sections.json (the ordered manifest) and inject each partial's HTML
  // into #grown in order. Adding a section = drop content/sections/NN-slug.html +
  // add a manifest row; it appears on the next page load. This mirrors how the
  // blog already ships as static HTML — the build no longer gates the agent's
  // work (the old import.meta.glob only updated on a Vite rebuild that never ran).
  // See WALDO.md for the content layout.
  import { mountGrown } from '../lib/stores.js';

  let host;
  // do the runtime fetch+inject once #grown is in the DOM. mountGrown owns the
  // fetch, ordering, injection, data-grown hooks, kicker renumbering and reveal
  // wiring — it lives in the engine so the follow/diff code shares it.
  $effect(() => { mountGrown(host); });
</script>

<!-- The agent's sections inject here at runtime (content/sections/*.html).
     Injecting raw HTML is safe here: every partial is first-party content the
     agent committed to this same-origin repo — never third-party or user input.
     No sanitizer dependency. -->
<div id="grown" bind:this={host}></div>

