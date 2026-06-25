<script>
  import Dna from './lib/Dna.svelte'
  import NexRail from './lib/NexRail.svelte'
  import Sidebar from './lib/Sidebar.svelte'
  import Chat from './lib/Chat.svelte'
  import Settings from './lib/Settings.svelte'
  import { ui } from './lib/data.svelte.js'

  // close the nexus menu on outside click
  function onWin() { ui.nexMenu = false }
</script>

<svelte:window onclick={onWin} />

<!-- the #app grid: 70px rail | 264px sidebar | 1fr main, with an 8px DNA row capping the first two -->
<div class="grid h-screen" style="grid-template-columns:70px 264px 1fr; grid-template-rows:8px 1fr">
  <div style="grid-column:1 / 3; grid-row:1"><Dna seed={11} height={8} /></div>
  <div style="grid-column:1; grid-row:2"><NexRail /></div>
  <div style="grid-column:2; grid-row:2; min-width:0"><Sidebar /></div>
  <div style="grid-column:3; grid-row:1 / 3; min-width:0"><Chat /></div>
</div>

{#if ui.settingsOpen}<Settings />{/if}
