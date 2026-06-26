<script>
  // Global search (Cmd-K) — the wired leaf action. Searches surfaces (name/purpose) and messages
  // (text) across every workspace via globalSearch(), and jumps to the chosen surface. Mirrors the
  // server-side intent: one query, ranked hits across the unified Surface/Message model.
  import { ui, globalSearch, surfaceById } from './data.svelte.js'
  import { iconSvgByName, iconSvg, KIND_COLOR } from './icons.js'

  let q = $state('')
  const res = $derived(globalSearch(q))

  function go(surfaceId, ws) {
    const s = surfaceById(surfaceId)
    if (s) { ui.surfaceId = s.id; ui.workspace = s.workspace; ui.section = 'studio' }
    close()
  }
  function close() { ui.searchOpen = false; q = '' }
  function onKey(e) { if (e.key === 'Escape') close() }
</script>

<svelte:window onkeydown={onKey} />

<div class="fixed inset-0 z-50 flex items-start justify-center pt-[12vh] bg-[color-mix(in_srgb,var(--color-ink)_22%,transparent)] backdrop-blur-sm"
  role="button" tabindex="-1" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="w-[min(620px,92vw)] rounded-2xl border border-line bg-paper shadow-2xl overflow-hidden">
    <div class="flex items-center gap-2.5 px-4 border-b border-line [&>svg]:w-4 [&>svg]:h-4 text-dim">
      {@html iconSvgByName('search', 16)}
      <!-- svelte-ignore a11y_autofocus -->
      <input autofocus bind:value={q} placeholder="Search channels, agents, messages…"
        class="flex-1 bg-transparent py-3.5 text-[15px] focus:outline-none text-ink" />
      <kbd class="text-[10px] font-mono text-dim border border-line rounded px-1.5 py-0.5">esc</kbd>
    </div>

    <div class="max-h-[52vh] overflow-y-auto">
      {#if !q.trim()}
        <div class="px-4 py-6 text-[13px] text-dim">Type to search across every workspace.</div>
      {:else if res.surfaces.length === 0 && res.messages.length === 0}
        <div class="px-4 py-6 text-[13px] text-dim">No matches for “{q}”.</div>
      {:else}
        {#if res.surfaces.length}
          <div class="px-4 pt-3 pb-1 text-[10px] font-mono uppercase tracking-wider text-dim">Surfaces</div>
          {#each res.surfaces as s}
            <button onclick={() => go(s.id, s.workspace)}
              class="w-full flex items-center gap-2.5 px-4 py-2 hover:bg-[color-mix(in_srgb,var(--color-ink)_6%,transparent)] text-left [&>svg]:w-4 [&>svg]:h-4"
              style="color:{KIND_COLOR[s.kind] || 'var(--color-ink)'}">
              {@html iconSvg(s.icon, s.kind, 16)}
              <span class="text-ink text-[14px]">{s.name}</span>
              {#if s.purpose}<span class="text-dim text-[12px] truncate">— {s.purpose}</span>{/if}
              <span class="ml-auto text-[10px] font-mono text-dim">{s.kind}</span>
            </button>
          {/each}
        {/if}
        {#if res.messages.length}
          <div class="px-4 pt-3 pb-1 text-[10px] font-mono uppercase tracking-wider text-dim">Messages</div>
          {#each res.messages as m}
            <button onclick={() => go(m.surfaceId)}
              class="w-full flex items-start gap-2.5 px-4 py-2 hover:bg-[color-mix(in_srgb,var(--color-ink)_6%,transparent)] text-left">
              <span class="text-dim text-[12px] font-mono flex-none pt-0.5">{m.author}</span>
              <span class="text-ink/85 text-[13px] line-clamp-1">{m.text}</span>
              {#if m.surface}<span class="ml-auto text-[10px] font-mono text-dim flex-none">{m.surface.name}</span>{/if}
            </button>
          {/each}
        {/if}
      {/if}
    </div>
  </div>
</div>
