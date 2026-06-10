<script>
  // The agent cursor: its tag, thought bubble, and flip logic are all driven
  // imperatively by the engine (lib/stores.js) through these registered refs.
  import { registerRef } from './stores.js';
  let cursorEl, thinkEl;
  $effect(() => {
    registerRef('cursor', cursorEl);
    registerRef('think', thinkEl);
  });
</script>

<div id="cursor" bind:this={cursorEl} aria-hidden="true">
  <svg width="17" height="19" viewBox="0 0 17 19" fill="none">
    <path d="M1 1L16 8.6L9.4 10.7L7 18L1 1Z" fill="#3fe081" stroke="#04130a" stroke-width="1.2"/>
  </svg>
  <span class="tag">waldo</span>
  <span class="think" id="think" bind:this={thinkEl}></span>
</div>
