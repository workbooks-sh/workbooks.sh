<script>
  import Wmark from '../lib/Wmark.svelte';
  import { reveal } from '../lib/stores.js';
</script>

<!-- who it's for: human-curated. The agent never edits this section. -->
<section id="who" class="band alt">
 <div class="inner">
  <div class="kicker reveal" use:reveal>02 · built for</div>
  <h2 class="reveal" use:reveal>From one person to the whole world</h2>
  <p class="lede reveal" use:reveal>The same app, at every size. Nothing gets rewritten
  on the way up.</p>
  <div class="lgrid wgrid">
    <div class="lcard c-green reveal" use:reveal>
      <span class="lk">for yourself</span>
      <p><b>The afternoon tool.</b> The tracker, the calculator, the little
      dashboard you always meant to make — built by describing it, kept
      because it's yours.</p>
      <span class="wmark"><Wmark /></span>
    </div>
    <div class="lcard c-blue reveal" use:reveal>
      <span class="lk">for your team</span>
      <p><b>The shared tool.</b> Hand the same app to ten people, run it on
      one runtime, change it Tuesday when the process changes.</p>
      <span class="wmark"><Wmark /></span>
    </div>
    <div class="lcard c-amber reveal" use:reveal>
      <span class="lk">for the world</span>
      <p><b>The product.</b> What you built for yourself is already built to
      serve everyone — same app, same runtime, public address.</p>
      <span class="wmark"><Wmark /></span>
    </div>
  </div>
 </div>
</section>
