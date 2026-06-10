<script>
  import AsciiField from '../lib/AsciiField.svelte';
  import Wmark from '../lib/Wmark.svelte';
  import { registerRef } from '../lib/stores.js';
  let h1textEl, caretEl;
  $effect(() => {
    registerRef('h1text', h1textEl);
    registerRef('caret', caretEl);
  });
</script>

<main class="hero">
  <AsciiField />
  <span class="mark blk" id="b-mark" aria-hidden="true">
    <Wmark />
  </span>

  <h1 class="blk" id="b-h1"><span id="h1text" bind:this={h1textEl}></span><span class="caret" id="caret" bind:this={caretEl} hidden></span></h1>

  <p class="sub blk" id="b-sub">
    <b>Workbooks</b> turns what you need into real software — an app for
    yourself, a tool for your team, a product for the world. The thing you
    build in an afternoon is already built to run at any scale. This is how
    software gets made now.
  </p>

  <div class="ctas blk" id="b-ctas">
    <a class="btn primary" href="https://github.com/workbooks-sh/workbooks.sh/releases/tag/desktop-v0.1.0" id="heroDl">download for desktop</a>
    <a class="btn ghost" href="#timeline">watch it work →</a>
  </div>
</main>
