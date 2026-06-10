<script>
  // The follow-mode viewer: a COMPACT fixed card on the right, docked just left
  // of the inspect panel (layout-level — it never overlaps the panel; when the
  // panel hides it slides to the edge). It shows the ACTION, a thought, and a
  // faint micro-preview — not a full document. The engine (lib/stores.js)
  // drives it imperatively through these registered refs so the one engine
  // keeps owning the cursor⇄viewer choreography (absorption).
  import { registerRef, viewerJump } from './stores.js';
  let winEl, headVerb, headThought, bodyEl;
  $effect(() => {
    registerRef('viewer', winEl);
    registerRef('viewerVerb', headVerb);
    registerRef('viewerThought', headThought);
    registerRef('viewerBody', bodyEl);
  });
</script>

<!-- hidden until follow mode opens it -->
<div id="viewer" class="viewer" bind:this={winEl} aria-hidden="true" onclick={viewerJump}
     role="button" tabindex="-1" onkeydown={(e) => e.key === 'Enter' && viewerJump()}>
  <div class="vinner">
    <div class="vhead">
      <span class="vdot" aria-hidden="true"></span>
      <span class="vverb" bind:this={headVerb}></span>
    </div>
    <div class="vthought" bind:this={headThought}></div>
    <div class="vbody" bind:this={bodyEl}></div>
  </div>
</div>
