<script>
  import { ui, surfaceById, messagesFor } from './data.svelte.js'
  import { ICO, KIND_ICON, KIND_COLOR } from './icons.js'
  import Message from './Message.svelte'
  import Composer from './Composer.svelte'

  const s = $derived(surfaceById(ui.surfaceId))
  const msgs = $derived(s ? messagesFor(s.id) : [])
</script>

{#if s}
  <section class="flex flex-col min-w-0 bg-paper h-full">
    <header class="flex items-center gap-2.5 px-4 h-[57px] border-b border-line flex-none">
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR[s.kind]}">{@html KIND_ICON[s.kind]}</span>
      <div class="min-w-0">
        <div class="font-display font-semibold leading-tight">{s.name}</div>
        <div class="text-dim text-[12.5px] truncate">{s.purpose}</div>
      </div>
      <span class="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-[color-mix(in_srgb,var(--color-ink)_7%,transparent)] text-dim font-mono">{s.kind}</span>
      <span class="flex-1"></span>
      <button class="flex items-center gap-1.5 text-dim hover:text-ink text-[13px] px-2.5 py-1.5 rounded-lg border border-line hoverwash
          {ui.mediaOpen ? '!text-ink !border-[color-mix(in_srgb,var(--color-ink)_30%,var(--color-line))]' : ''}"
        onclick={() => { ui.mediaOpen = !ui.mediaOpen; ui.settingsOpen = false }} title="Files & media">{@html ICO.tree} Files</button>
      <button class="flex items-center gap-1.5 text-dim hover:text-ink text-[13px] px-2.5 py-1.5 rounded-lg border border-line hoverwash"
        onclick={() => { ui.settingsOpen = !ui.settingsOpen; ui.mediaOpen = false }}>{@html ICO.gear} Settings</button>
    </header>

    <div class="flex-1 overflow-y-auto px-4 py-3.5 flex flex-col gap-3">
      {#each msgs as m (m.id)}<Message {m} />{/each}
    </div>

    <Composer surfaceId={s.id} />
  </section>
{/if}
