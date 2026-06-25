<script>
  // A person's profile, shown as an overlay over the sidebar when you click their avatar.
  // The primary action is "Message" → opens (or creates) a DM thread with them.
  import { ui, personByName, avatarOf, openDM } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  const p = $derived(personByName(ui.profile))
  const STATUS = {
    active:  { c: 'var(--color-mint)', label: 'Active' },
    away:    { c: 'var(--color-cream)', label: 'Away' },
    offline: { c: 'var(--color-line)', label: 'Offline' }
  }
  const st = $derived(STATUS[p?.status] || STATUS.offline)
</script>

{#if p}
  <!-- overlay panel: sits over the sidebar, dismiss by clicking the backdrop or the X -->
  <div class="absolute inset-0 z-40" role="presentation" onclick={() => (ui.profile = null)}>
    <div class="absolute inset-x-2.5 top-2.5 rounded-2xl border border-line bg-card overflow-hidden"
      style="box-shadow:0 20px 50px rgba(0,0,0,.45)" role="dialog" tabindex="-1"
      onclick={(e) => e.stopPropagation()}>
      <!-- banner -->
      <div class="h-14" style="background:linear-gradient(135deg,color-mix(in srgb,var(--color-sky) 60%,transparent),color-mix(in srgb,var(--color-fuchsia) 45%,transparent))"></div>
      <button class="absolute right-2.5 top-2.5 w-7 h-7 rounded-lg grid place-items-center text-ink/70 hover:text-ink bg-[color-mix(in_srgb,var(--color-card)_70%,transparent)] [&>svg]:w-[15px] [&>svg]:h-[15px]"
        onclick={() => (ui.profile = null)} title="Close">{@html iconSvgByName('xmark', 15)}</button>

      <div class="px-4 pb-4 -mt-7">
        <img src={avatarOf(p.name, 'human')} alt={p.name}
          class="w-14 h-14 rounded-xl border-2 border-card object-cover bg-paper" />
        <div class="mt-2 flex items-center gap-2">
          <span class="font-display font-semibold text-[16px]">{p.name}</span>
          <span class="flex items-center gap-1 text-[11px] text-dim">
            <span class="w-2 h-2 rounded-full" style="background:{st.c}"></span>{st.label}
          </span>
        </div>
        <div class="text-dim text-[12.5px] mt-0.5">{p.role}</div>
        <p class="text-ink/80 text-[13px] mt-2.5 leading-snug">{p.blurb}</p>

        <div class="mt-3.5 flex items-center gap-2">
          <button onclick={() => openDM(p.name)}
            class="flex-1 flex items-center justify-center gap-2 text-[13px] font-medium px-3 py-2 rounded-lg text-ink
              bg-[color-mix(in_srgb,var(--color-sky)_30%,transparent)] hover:bg-[color-mix(in_srgb,var(--color-sky)_45%,transparent)] [&>svg]:w-[15px] [&>svg]:h-[15px]">
            {@html iconSvgByName('chat-bubble', 15)} Message
          </button>
          <button class="w-9 h-9 rounded-lg grid place-items-center border border-line text-dim hover:text-ink hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]" title="More">{@html iconSvgByName('more-horiz', 15)}</button>
        </div>
      </div>
    </div>
  </div>
{/if}
