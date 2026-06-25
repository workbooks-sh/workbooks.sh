<script>
  import { ui, entityById, messagesFor } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'
  const s = $derived(entityById(ui.surfaceId))
  const atts = $derived(messagesFor(ui.surfaceId).flatMap((m) => (m.attachments || []).map((a) => ({ ...a, author: m.author, ts: m.ts }))))
  const images = $derived(atts.filter((a) => a.type === 'image'))
  const files = $derived(atts.filter((a) => a.type === 'file'))
  // a DM's "members" = the people in it (plus you); a channel uses the demo count.
  const memberCount = $derived(s?.dm ? `${(s.members?.length || 1) + 1}` : '4')
</script>

{#if s}
  <div class="fixed top-0 right-0 h-screen w-[320px] bg-paper border-l border-line z-30 flex flex-col"
    style="box-shadow:-20px 0 40px rgba(0,0,0,.35)">
    <div class="flex items-center gap-2 px-4 h-[57px] border-b border-line flex-none">
      <span class="font-display font-semibold text-[15px] flex-1">Info</span>
      <button class="text-dim hover:text-ink text-lg" onclick={() => (ui.mediaOpen = false)}>×</button>
    </div>

    <div class="flex-1 overflow-y-auto p-4">
      <!-- per-chat options -->
      <div class="flex flex-col gap-1 mb-5">
        {#each [['group', 'Members', memberCount], ['pin', 'Pinned', '2'], ['bell', 'Notifications', 'All']] as [ic, label, val]}
          <button class="flex items-center gap-2.5 px-2 py-2 rounded-lg hoverwash text-[13.5px]">
            <span class="text-dim grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html iconSvgByName(ic, 16)}</span>
            <span class="flex-1 text-left">{label}</span><span class="text-dim text-[12px]">{val}</span>
          </button>
        {/each}
      </div>

      <div class="text-[10px] font-mono uppercase tracking-widest text-dim mb-2">Media · {images.length}</div>
      {#if images.length}
        <div class="grid grid-cols-3 gap-1.5 mb-5">
          {#each images as a}
            <div class="aspect-square rounded-lg border border-line overflow-hidden grid place-items-center"
              style="background:{a.url ? 'transparent' : `color-mix(in srgb,${a.color} 50%,transparent)`}">
              {#if a.url}<img src={a.url} alt={a.name} class="w-full h-full object-cover" />{/if}
            </div>
          {/each}
        </div>
      {:else}<div class="text-dim text-[12.5px] mb-5">No images yet.</div>{/if}

      <div class="text-[10px] font-mono uppercase tracking-widest text-dim mb-2">Files · {files.length}</div>
      {#if files.length}
        <div class="flex flex-col gap-1.5">
          {#each files as a}
            <div class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg border border-line bg-card">
              <span class="w-8 h-8 rounded grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]"
                style="background:color-mix(in srgb,var(--color-sky) 35%,transparent);color:var(--color-ink)">{@html iconSvgByName('empty-page', 15)}</span>
              <div class="min-w-0 flex-1"><div class="text-[13px] truncate">{a.name}</div><div class="text-dim text-[11px]">{a.author} · {a.size}</div></div>
            </div>
          {/each}
        </div>
      {:else}<div class="text-dim text-[12.5px]">No files yet.</div>{/if}
    </div>
  </div>
{/if}
