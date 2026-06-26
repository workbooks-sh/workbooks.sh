<script>
  // The IDE surface (epic wb-pntm) — the FULL VS Code workbench: activity bar · file explorer · editor groups
  // · panel (Terminal/Output) · status bar · command palette. The workbench parts are attached into the grid
  // cells below; it's backed by an in-memory FS seeded from the mock tree (fs.svelte.js). Terminal/run/search
  // slots render now; they get wired to washy later (registry/ide-shell.work).
  import { onMount } from 'svelte'

  let root, activitybar, sidebar, editor, panel, statusbar
  let status = $state('booting the workbench…')
  let failed = $state(null)

  onMount(async () => {
    try {
      const wb = await import('./ide/workbench.js')
      await wb.bootWorkbench(root)
      wb.attachParts({ activitybar, sidebar, editor, panel, statusbar })
      status = ''
    } catch (e) {
      console.error('[ide] workbench boot failed', e)
      failed = String(e?.stack || e)
      status = ''
    }
  })
</script>

<div class="h-full w-full relative bg-well min-w-0 min-h-0">
  {#if status}<div class="absolute inset-0 z-10 grid place-items-center text-dim text-[13px] animate-pulse bg-well">{status}</div>{/if}
  {#if failed}<pre class="absolute inset-0 z-10 overflow-auto m-0 p-4 text-[12px] font-mono text-[var(--color-bad)] whitespace-pre-wrap bg-well">{failed}</pre>{/if}

  <div bind:this={root} class="ide-root" class:invisible={!!status || !!failed}>
    <div bind:this={activitybar} class="ide-activitybar"></div>
    <div bind:this={sidebar} class="ide-sidebar"></div>
    <div bind:this={editor} class="ide-editor"></div>
    <div bind:this={panel} class="ide-panel"></div>
    <div bind:this={statusbar} class="ide-statusbar"></div>
  </div>
</div>

<style>
  .ide-root {
    height: 100%; width: 100%;
    display: grid;
    grid-template-columns: 48px 240px minmax(0, 1fr);
    grid-template-rows: minmax(0, 1fr) auto 22px;
    grid-template-areas:
      "activity sidebar editor"
      "activity sidebar panel"
      "status   status  status";
    background: var(--color-well);
    overflow: hidden;
  }
  .ide-activitybar { grid-area: activity; min-height: 0; overflow: hidden; }
  .ide-sidebar { grid-area: sidebar; min-height: 0; overflow: hidden; }
  .ide-editor { grid-area: editor; min-width: 0; min-height: 0; overflow: hidden; }
  .ide-panel { grid-area: panel; min-width: 0; overflow: hidden; }
  .ide-statusbar { grid-area: status; min-width: 0; overflow: hidden; }
</style>
