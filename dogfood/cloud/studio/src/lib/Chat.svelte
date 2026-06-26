<script>
  import { ui, entityById, messagesFor, isRootWs } from './data.svelte.js'
  import { iconSvg, iconSvgByName, KIND_COLOR } from './icons.js'
  import Message from './Message.svelte'
  import Composer from './Composer.svelte'
  import CapabilityBadge from './CapabilityBadge.svelte'

  const s = $derived(entityById(ui.surfaceId))
  // the channel feed shows TOP-LEVEL messages only; replies live in their thread (Nexus.Chat.roots).
  const msgs = $derived(s ? messagesFor(s.id).filter((m) => !m.parent) : [])
  // right-panel mutual exclusion: opening a thread closes media + settings
  const openThread = (m) => { ui.thread = m.id; ui.mediaOpen = false; ui.settingsOpen = false }
</script>

{#if s}
  <section class="flex flex-col min-w-0 bg-paper h-full">
    <header class="flex items-center gap-2.5 px-4 h-[57px] border-b border-line flex-none">
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR[s.kind]}">{@html iconSvg(s.icon, s.kind)}</span>
      <div class="min-w-0">
        <div class="font-display font-semibold leading-tight">{s.name}</div>
        <div class="text-dim text-[12.5px] truncate">{s.purpose}</div>
      </div>
      <span class="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-[color-mix(in_srgb,var(--color-ink)_7%,transparent)] text-dim font-mono">{s.dm ? 'direct message' : s.kind}</span>
      {#if s.kind === 'agent'}<CapabilityBadge agent={s.name} />{/if}
      {#if isRootWs(s.workspace)}
        <span class="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded font-mono" style="color:var(--color-violet);background:color-mix(in srgb,var(--color-violet) 18%,transparent)" title="Org-scoped · highest permission tier">org · highest scope</span>
      {/if}
      <span class="flex-1"></span>
      <!-- icon-only header actions. Info = people / pinned / shared media (applies to channels, agents
           AND DMs). Settings = configure this surface — hidden for DMs (you don't configure a DM). -->
      <button title="Info" aria-label="Info"
        class="w-8 h-8 grid place-items-center text-dim hover:text-ink rounded-lg border border-line hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px]
          {ui.mediaOpen ? '!text-ink !border-[color-mix(in_srgb,var(--color-ink)_30%,var(--color-line))]' : ''}"
        onclick={() => { ui.mediaOpen = !ui.mediaOpen; ui.settingsOpen = false; ui.thread = null }}>{@html iconSvgByName('info-circle', 16)}</button>
      {#if !s.dm}
        <button title="Settings" aria-label="Settings"
          class="w-8 h-8 grid place-items-center text-dim hover:text-ink rounded-lg border border-line hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px]
            {ui.settingsOpen ? '!text-ink !border-[color-mix(in_srgb,var(--color-ink)_30%,var(--color-line))]' : ''}"
          onclick={() => { ui.settingsOpen = !ui.settingsOpen; ui.mediaOpen = false; ui.thread = null; ui.wsSettings = null }}>{@html iconSvgByName('settings', 16)}</button>
      {/if}
    </header>

    <div class="flex-1 overflow-y-auto px-4 py-3.5 flex flex-col gap-3">
      {#each msgs as m (m.id)}<Message {m} onOpenThread={openThread} />{/each}
    </div>

    <Composer surfaceId={s.id} />
  </section>
{/if}
