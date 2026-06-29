<script>
  // The Command Palette (⌘⇧P) — the universal "run an action" surface. It merges WORKBENCH commands with
  // commands CONTRIBUTED by extensions (ext-host extCommands()), so an installed extension's actions have a
  // home. Mirrors VS Code's palette: type to filter, ↑/↓ to move, ⏎ to run.
  import { iconSvgByName } from './icons.js'

  let { commands, onClose } = $props()
  let query = $state('')
  let sel = $state(0)

  const filtered = $derived(
    commands.filter((c) => c.title.toLowerCase().includes(query.toLowerCase()))
  )
  $effect(() => { query; sel = 0 }) // reset selection as the query changes

  function run(c) { onClose(); c?.run?.() }
  function onKey(e) {
    if (e.key === 'ArrowDown') { sel = Math.min(sel + 1, filtered.length - 1); e.preventDefault() }
    else if (e.key === 'ArrowUp') { sel = Math.max(sel - 1, 0); e.preventDefault() }
    else if (e.key === 'Enter') { run(filtered[sel]); e.preventDefault() }
    else if (e.key === 'Escape') { onClose() }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<div class="fixed inset-0 z-[75] flex items-start justify-center pt-[12vh]" style="background:color-mix(in srgb,var(--color-ink) 22%,transparent)"
  onclick={onClose}>
  <div class="w-[560px] max-w-[92vw] rounded-2xl border border-line overflow-hidden" style="background:var(--color-card); box-shadow:0 30px 70px rgba(0,0,0,.4)"
    onclick={(e) => e.stopPropagation()}>
    <div class="flex items-center gap-2.5 px-3.5 h-[46px] border-b border-line">
      <span class="grid place-items-center text-dim [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html iconSvgByName('search', 16)}</span>
      <!-- svelte-ignore a11y_autofocus -->
      <input bind:value={query} onkeydown={onKey} autofocus spellcheck="false" placeholder="Run a command…"
        class="flex-1 min-w-0 bg-transparent border-0 focus:outline-none text-[14px]" style="color:var(--color-ink)" />
      <kbd class="text-[10px] font-mono text-dim px-1.5 py-0.5 rounded border border-line">esc</kbd>
    </div>
    <div class="max-h-[44vh] overflow-y-auto py-1.5">
      {#if !filtered.length}
        <div class="px-4 py-5 text-center text-dim text-[12.5px]">no matching commands</div>
      {:else}
        {#each filtered as c, i}
          <button onclick={() => run(c)} onmouseenter={() => (sel = i)}
            class="flex items-center gap-2.5 w-full text-left px-4 py-2 text-[13px]"
            style={i === sel ? 'background:color-mix(in srgb,var(--color-sky) 26%,transparent);color:var(--color-ink)' : 'color:var(--color-ink)'}>
            <span class="grid place-items-center text-dim [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName(c.hint === 'extension' ? 'puzzle' : 'play', 14)}</span>
            <span class="flex-1 truncate">{c.title}</span>
            {#if c.hint === 'extension'}<span class="text-[10px] uppercase tracking-wide text-dim/70">extension</span>{/if}
          </button>
        {/each}
      {/if}
    </div>
  </div>
</div>
