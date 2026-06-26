<script>
  // The IDE surface (recon spike, bd wb-8st4). Mounts the monaco-vscode-api editor into a DOM node on mount.
  // For now it loads a sample .work file so we can eyeball the editor + theme inside our chrome. Next steps
  // (per registry/ide-shell.work): back it with the mock VFS, add the workbench layout, theme it to our tokens.
  import { onMount, onDestroy } from 'svelte'

  let host
  let editor
  let status = $state('booting the workbench…')
  let failed = $state(null)

  const SAMPLE = `workbook :hello, type: :app\n\n# Hello from the IDE island\n\nThis editor is monaco-vscode-api booted client-side in our vite build —\nno backend, no container. The recon question: does the shell render in\nour pipeline? If you can read this, the answer is yes.\n\nserver :greet do\n  IO.puts("hello from a .work server unit")\nend\n`

  onMount(async () => {
    try {
      const { mountEditor } = await import('./ide/boot.js')
      editor = await mountEditor(host, { value: SAMPLE, language: 'plaintext' })
      status = ''
    } catch (e) {
      console.error('[ide] boot failed', e)
      failed = String(e?.stack || e)
      status = ''
    }
  })

  onDestroy(() => editor?.dispose?.())
</script>

<div class="h-full w-full flex flex-col bg-well min-w-0 min-h-0">
  <div class="flex items-center gap-2 h-[46px] px-4 border-b border-line flex-none">
    <span class="font-display font-semibold text-[15px]">Code</span>
    <span class="text-[11px] font-mono text-dim">monaco-vscode-api · recon spike</span>
  </div>

  {#if status}
    <div class="flex-1 grid place-items-center text-dim text-[13px] animate-pulse">{status}</div>
  {/if}
  {#if failed}
    <pre class="flex-1 overflow-auto m-0 p-4 text-[12px] font-mono text-[var(--color-bad)] whitespace-pre-wrap">{failed}</pre>
  {/if}

  <div bind:this={host} class="flex-1 min-h-0" class:hidden={!!status || !!failed}></div>
</div>
