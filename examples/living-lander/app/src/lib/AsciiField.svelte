<script>
  import { startAscii } from './stores.js';
  let cv;
  $effect(() => { startAscii(cv); });
</script>

<canvas id="ascii" bind:this={cv} aria-hidden="true"></canvas>
