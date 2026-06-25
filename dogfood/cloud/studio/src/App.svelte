<script>
  import Dna from './lib/Dna.svelte'
  import NexRail from './lib/NexRail.svelte'
  import Sidebar from './lib/Sidebar.svelte'
  import Main from './lib/Main.svelte'
  import FileTree from './lib/FileTree.svelte'
  import FileEditor from './lib/FileEditor.svelte'
  import Settings from './lib/Settings.svelte'
  import MediaPanel from './lib/MediaPanel.svelte'
  import { ui } from './lib/data.svelte.js'

  // close the nexus menu on outside click
  function onWin() { ui.nexMenu = false }
</script>

<svelte:window onclick={onWin} />

<!-- the #app grid: 70px rail | 264px sidebar | 1fr main, with an 8px DNA row capping the first two.
     minmax(0,1fr) + min-height:0 caps every column to the viewport so tall content scrolls INSIDE its
     column (the sidebar nav, the main pane) instead of stretching the whole app past the screen. -->
<div class="grid h-screen overflow-hidden" style="grid-template-columns:70px 264px 1fr; grid-template-rows:8px minmax(0,1fr)">
  <div style="grid-column:1 / 3; grid-row:1"><Dna seed={11} height={8} /></div>
  <div style="grid-column:1; grid-row:2; min-height:0; overflow:hidden"><NexRail /></div>
  {#if ui.section === 'files'}
    <!-- Files IDE mirrors Studio's layout: the file tree sits under the DNA bar (like the sidebar),
         the editor spans both rows so CodeMirror is full height (like Main). -->
    <div style="grid-column:2; grid-row:2; min-width:0; min-height:0; overflow:hidden"><FileTree /></div>
    <div style="grid-column:3; grid-row:1 / 3; min-width:0; min-height:0; overflow:hidden"><FileEditor /></div>
  {:else}
    <div style="grid-column:2; grid-row:2; min-width:0; min-height:0; overflow:hidden"><Sidebar /></div>
    <div style="grid-column:3; grid-row:1 / 3; min-width:0; min-height:0; overflow:hidden"><Main /></div>
  {/if}
</div>

{#if ui.settingsOpen}<Settings />{/if}
{#if ui.mediaOpen}<MediaPanel />{/if}
