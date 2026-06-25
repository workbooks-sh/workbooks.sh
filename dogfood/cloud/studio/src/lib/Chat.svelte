<script>
  import { ui, surfaceById, messagesFor, send } from './data.svelte.js'
  import { ICO } from './icons.js'

  const s = $derived(surfaceById(ui.surfaceId))
  const msgs = $derived(s ? messagesFor(s.id) : [])
  let draft = $state('')

  function onKey(e) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(s.id, draft); draft = '' }
  }
  const initials = (a) => a.slice(0, 2).toUpperCase()
</script>

{#if s}
  <section class="flex flex-col min-w-0 bg-paper h-full">
    <header class="flex items-center gap-2.5 px-4 h-[57px] border-b border-line flex-none">
      <span class="text-lg">{s.icon}</span>
      <div class="min-w-0">
        <div class="font-display font-semibold leading-tight">{s.name}</div>
        <div class="text-dim text-[12.5px] truncate">{s.purpose}</div>
      </div>
      <span class="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded
        bg-[color-mix(in_srgb,var(--color-ink)_7%,transparent)] text-dim font-mono">{s.kind}</span>
      <span class="flex-1"></span>
      <button class="flex items-center gap-1.5 text-dim hover:text-ink text-[13px] px-2.5 py-1.5 rounded-lg border border-line hoverwash"
        onclick={() => (ui.settingsOpen = !ui.settingsOpen)}>{@html ICO.gear} Settings</button>
    </header>

    <div class="flex-1 overflow-y-auto px-4 py-3.5 flex flex-col gap-3">
      {#each msgs as m (m.id)}
        <div class="flex gap-2.5">
          <div class="w-7 h-7 rounded-[7px] flex-none grid place-items-center text-[13px] font-bold font-mono text-[#10120f]"
            style="background:{m.kind === 'agent' ? 'linear-gradient(135deg,var(--color-violet),var(--color-blue))'
              : m.kind === 'system' ? 'linear-gradient(135deg,var(--color-mint),var(--color-sage))'
              : 'linear-gradient(135deg,var(--color-peach),var(--color-cream))'}">
            {m.kind === 'system' ? '🛎️' : initials(m.author)}
          </div>
          <div class="min-w-0">
            <div class="flex gap-2 items-baseline">
              <span class="font-semibold {m.kind === 'agent' ? 'text-pause' : m.kind === 'system' ? 'text-bloomd' : ''}">{m.author}</span>
              <span class="text-dim text-[11px] font-mono">{m.ts}</span>
            </div>
            <div class="whitespace-pre-wrap text-ink/90">{m.text}</div>
          </div>
        </div>
      {/each}
    </div>

    <div class="px-4 py-3 border-t border-line">
      <textarea bind:value={draft} onkeydown={onKey}
        placeholder={`Message ${s.name} — @agent to summon, /workflow to run`}
        class="w-full resize-none bg-card border border-line rounded-xl px-3 py-2.5 min-h-[42px]
          focus:outline-none focus:border-[color-mix(in_srgb,var(--color-bloom)_60%,var(--color-line))]"></textarea>
      <div class="text-dim text-[11px] mt-1.5">@-mention an agent · /run a workflow · everything is one channel, no inbox</div>
    </div>
  </section>
{/if}
