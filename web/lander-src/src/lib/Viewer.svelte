<script>
  // The follow-mode viewer window: a fixed bottom-right pane that shows what
  // Waldo is reading when his step lands OFF the page (a remote URL or a repo
  // file not visible here). The engine (lib/stores.js) drives it imperatively
  // through these registered refs — open()/close()/show* live there so the one
  // engine keeps owning the cursor⇄viewer choreography (cursor absorption).
  import { registerRef } from './stores.js';
  let winEl, headVerb, headThought, bodyEl;
  $effect(() => {
    registerRef('viewer', winEl);
    registerRef('viewerVerb', headVerb);
    registerRef('viewerThought', headThought);
    registerRef('viewerBody', bodyEl);
  });
</script>

<!-- hidden until follow mode opens it; the gradient stroke is a ::before mask -->
<div id="viewer" class="viewer" bind:this={winEl} aria-hidden="true">
  <div class="vhead">
    <span class="vverb" bind:this={headVerb}></span>
    <span class="vthought" bind:this={headThought}></span>
  </div>
  <div class="vbody" bind:this={bodyEl}></div>
</div>
