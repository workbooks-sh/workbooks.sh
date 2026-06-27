<script>
  import Dna from './lib/Dna.svelte'
  import NexRail from './lib/NexRail.svelte'
  import Sidebar from './lib/Sidebar.svelte'
  import Main from './lib/Main.svelte'
  import Settings from './lib/Settings.svelte'
  import MediaPanel from './lib/MediaPanel.svelte'
  import SearchPalette from './lib/SearchPalette.svelte'
  import ThreadPanel from './lib/ThreadPanel.svelte'
  import Toolkits from './lib/Toolkits.svelte'
  import ToolkitsNav from './lib/ToolkitsNav.svelte'
  import ToolkitDetail from './lib/ToolkitDetail.svelte'
  import ProviderDetail from './lib/ProviderDetail.svelte'
  import SecretsModal from './lib/SecretsModal.svelte'
  import AuthTerminal from './lib/AuthTerminal.svelte'
  import You from './lib/You.svelte'
  import YouNav from './lib/YouNav.svelte'
  import CodeIde from './lib/CodeIde.svelte'
  import ResizeHandle from './lib/ResizeHandle.svelte'
  import AppFooter from './lib/AppFooter.svelte'
  import AuxPanel from './lib/AuxPanel.svelte'
  import { ui } from './lib/data.svelte.js'

  let sidebarW = $state(264) // Studio/Toolkits/You sidebar width — drag-resizable

  // close the nexus menu on outside click
  function onWin() { ui.nexMenu = false }
  // Cmd/Ctrl-K opens the global search palette
  function onKey(e) {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); ui.searchOpen = true }
  }
</script>

<svelte:window onclick={onWin} onkeydown={onKey} />

<!-- the #app grid: 70px rail | 264px sidebar | 1fr main, with an 8px DNA row capping the first two.
     minmax(0,1fr) + min-height:0 caps every column to the viewport so tall content scrolls INSIDE its
     column (the sidebar nav, the main pane) instead of stretching the whole app past the screen. -->
<div class="grid h-screen overflow-hidden relative" style="grid-template-columns:70px {sidebarW}px minmax(0,1fr) {ui.auxView ? '340px' : '0px'}; grid-template-rows:8px minmax(0,1fr) 24px">
  <div style="grid-column:1 / 3; grid-row:1"><Dna seed={11} height={8} /></div>
  <div style="grid-column:1; grid-row:2; min-height:0; overflow:hidden"><NexRail /></div>
  <!-- persistent right-side aux panel (a contributed VIEW / MCP-App) — across every section -->
  {#if ui.auxView}
    <div style="grid-column:4; grid-row:1 / 3; min-width:0; min-height:0; overflow:hidden; border-left:1px solid var(--color-line)"><AuxPanel /></div>
  {/if}
  <!-- one resize handle at the sidebar↔main boundary, for every non-Code section (Code has its own) -->
  {#if ui.section !== 'code'}
    <ResizeHandle value={sidebarW} min={210} max={520} onchange={(w) => (sidebarW = w)}
      class="absolute top-0 z-40" style={`left:${70 + sidebarW - 4}px; bottom:24px`} />
  {/if}
  <!-- the app-wide footer: real live state across every section -->
  <div style="grid-column:1 / 5; grid-row:3; min-width:0"><AppFooter /></div>
  {#if ui.section === 'code'}
    <!-- Code workbench: our OWN custom Svelte IDE (floating toolbar · tree · editor · terminal panel),
         no embedded VS Code. The file surface lives here now (Files was folded in). Spans rail-to-edge. -->
    <div style="grid-column:2 / 4; grid-row:1 / 3; min-width:0; min-height:0; overflow:hidden"><CodeIde /></div>
  {:else if ui.section === 'toolkits'}
    <!-- Toolkits keeps the settings-page shape: a Connected/Browse sub-nav + the catalog (like Files/You). -->
    <div style="grid-column:2; grid-row:2; min-width:0; min-height:0; overflow:hidden"><ToolkitsNav /></div>
    <div style="grid-column:3; grid-row:1 / 3; min-width:0; min-height:0; overflow:hidden"><Toolkits /></div>
  {:else if ui.section === 'you'}
    <!-- You keeps the legacy settings-page shape: a sub-nav column + the scrolling page (like Files). -->
    <div style="grid-column:2; grid-row:2; min-width:0; min-height:0; overflow:hidden"><YouNav /></div>
    <div style="grid-column:3; grid-row:1 / 3; min-width:0; min-height:0; overflow:hidden"><You /></div>
  {:else}
    <div style="grid-column:2; grid-row:2; min-width:0; min-height:0; overflow:hidden"><Sidebar /></div>
    <div style="grid-column:3; grid-row:1 / 3; min-width:0; min-height:0; overflow:hidden"><Main /></div>
  {/if}
</div>

{#if ui.toolkitDetail}<ToolkitDetail />{/if}
{#if ui.providerDetail}<ProviderDetail />{/if}
{#if ui.secretsModal}<SecretsModal />{/if}
{#if ui.authTerminal}<AuthTerminal />{/if}
{#if ui.settingsOpen}<Settings />{/if}
{#if ui.mediaOpen}<MediaPanel />{/if}
{#if ui.searchOpen}<SearchPalette />{/if}
{#if ui.thread}<ThreadPanel />{/if}
