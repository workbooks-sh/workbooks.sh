<script>
  import Wmark from '../lib/Wmark.svelte';
  import { reveal } from '../lib/stores.js';
</script>

<!-- the three layers: human-curated. The agent never edits this section. -->
<section id="layers" class="band">
 <div class="inner">
  <div class="kicker reveal" use:reveal>01 · the stack</div>
  <h2 class="reveal" use:reveal>How it fits together</h2>
  <div class="lgrid">
    <div class="lcard c-green reveal" use:reveal>
      <span class="lk">workbooks</span>
      <p><b>The apps.</b> Everything an app is — its data, its logic, its
      interface — travels as one piece you can open anywhere, share like a
      file, and reshape like a document.</p>
      <span class="wmark"><Wmark /></span>
    </div>
    <div class="lcard c-blue reveal" use:reveal>
      <span class="lk">the runtime</span>
      <p><b>The engine.</b> One server runs your apps, their agents, and
      everything they do — on a laptop, across a company, or for the open
      internet, without changing a line.</p>
      <span class="wmark"><Wmark /></span>
    </div>
    <div class="lcard c-amber reveal" use:reveal>
      <span class="lk">toolkits</span>
      <p><b>How it grows.</b> Every capability — charts, AI, payments,
      whatever's next — is authored the same way, so what you start with is
      never what you're stuck with.</p>
      <span class="wmark"><Wmark /></span>
    </div>
  </div>
 </div>
</section>
