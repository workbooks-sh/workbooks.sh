<script>
  // "from the agent's desk" — the on-page blog listing. It is manifest-driven:
  // mountAgentsDesk fetches /content/blog.json (the SAME source the blog index
  // reads) and renders the rows. Because both views read one manifest, a new
  // post can never be present on the index but forgotten here. Empty/missing
  // manifest → the whole section stays hidden (no empty shell, no errors).
  import { mountAgentsDesk } from '../lib/stores.js';
  let host;
  $effect(() => { mountAgentsDesk(host); });
</script>

<div bind:this={host}></div>
