<script>
  // Thread panel — the wired thread leaf action. Shows a root message and its replies (Nexus.Chat
  // single-level threads: parent → root), with a composer that posts replies via sendReply. Slides
  // in over the right edge like the media/settings panels.
  import { tick } from 'svelte'
  import { ui, messages, repliesOf, sendReply, mentionCandidates, entityById, avatarOf } from './data.svelte.js'
  import Message from './Message.svelte'
  import { iconSvgByName } from './icons.js'

  const root = $derived(messages.find((m) => m.id === ui.thread))
  const replies = $derived(root ? repliesOf(root.id) : [])
  const ws = $derived(entityById(root?.surfaceId)?.workspace)
  let draft = $state('')
  let active = $state(0)
  let ta

  // lightweight @-mention picker — filter candidates on a trailing @token
  const picker = $derived.by(() => {
    const men = draft.match(/(?:^|\s)@(\w*)$/)
    if (!men || !ws) return null
    const q = men[1].toLowerCase()
    return mentionCandidates(ws).filter((r) => r.name.toLowerCase().startsWith(q))
  })
  $effect(() => { if (picker) active = Math.min(active, Math.max(0, picker.length - 1)) })

  function choose(row) {
    draft = draft.replace(/(^|\s)@\w*$/, (m, pre) => `${pre}@${row.name} `)
    active = 0
    tick().then(() => ta?.focus())
  }

  function post() {
    if (!draft.trim()) return
    sendReply(root.id, draft)
    draft = ''
  }
  function onKey(e) {
    if (picker && picker.length) {
      if (e.key === 'ArrowDown') { e.preventDefault(); active = (active + 1) % picker.length; return }
      if (e.key === 'ArrowUp') { e.preventDefault(); active = (active - 1 + picker.length) % picker.length; return }
      if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); choose(picker[active]); return }
      if (e.key === 'Escape') { draft = draft.replace(/(^|\s)@\w*$/, '$1'); return }
    }
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); post() }
    if (e.key === 'Escape') ui.thread = null
  }
</script>

{#if root}
  <aside class="fixed top-0 right-0 h-screen w-[min(420px,92vw)] z-40 bg-paper border-l border-line shadow-2xl flex flex-col">
    <header class="flex items-center gap-2 px-4 h-[57px] border-b border-line flex-none">
      <span class="font-display font-semibold">Thread</span>
      <span class="text-dim text-[12px]">{replies.length} {replies.length === 1 ? 'reply' : 'replies'}</span>
      <span class="flex-1"></span>
      <button aria-label="Close thread" onclick={() => (ui.thread = null)}
        class="w-8 h-8 grid place-items-center text-dim hover:text-ink rounded-lg border border-line [&>svg]:w-4 [&>svg]:h-4">{@html iconSvgByName('xmark', 16)}</button>
    </header>

    <div class="flex-1 overflow-y-auto px-4 py-3.5 flex flex-col gap-3">
      <Message m={root} />
      {#if replies.length}
        <div class="flex items-center gap-2 text-[11px] text-dim my-1">
          <span class="h-px flex-1 bg-line"></span>{replies.length} {replies.length === 1 ? 'reply' : 'replies'}<span class="h-px flex-1 bg-line"></span>
        </div>
      {/if}
      {#each replies as r (r.id)}<Message m={r} />{/each}
    </div>

    <div class="p-3 border-t border-line flex-none relative">
      {#if picker && picker.length}
        <div class="absolute bottom-full left-3 right-3 mb-2 rounded-2xl border border-line bg-card overflow-hidden z-20"
          style="box-shadow:0 20px 48px rgba(0,0,0,.4)">
          <div class="flex items-center gap-1.5 px-3 py-1.5 text-[10px] font-mono uppercase tracking-widest text-dim border-b border-line [&>svg]:w-3 [&>svg]:h-3">
            {@html iconSvgByName('at-sign', 12)} Mention a person or agent
          </div>
          <div class="max-h-[220px] overflow-y-auto py-1">
            {#each picker as r, i}
              {@const c = r.kind === 'agent' ? 'var(--color-fuchsia)' : 'var(--color-dim)'}
              <button class="flex items-center gap-2.5 w-full text-left px-3 py-2 {i === active ? 'bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)]' : ''} hoverwash"
                onmouseenter={() => (active = i)} onclick={() => choose(r)}>
                {#if r.kind === 'person'}
                  <img src={avatarOf(r.name, 'human')} alt={r.name} class="w-6 h-6 rounded-md object-cover flex-none border border-line" />
                {:else}
                  <span class="w-6 h-6 flex-none grid place-items-center rounded-md [&>svg]:w-[15px] [&>svg]:h-[15px]"
                    style="color:{c};background:color-mix(in srgb,{c} 16%,transparent)">{@html iconSvgByName(r.icon || (r.kind === 'agent' ? 'cpu' : 'sparks'), 15)}</span>
                {/if}
                <span class="font-medium text-[13.5px] flex-none"><span class="text-dim">@</span>{r.name}</span>
                {#if r.kind === 'agent'}<span class="ml-auto text-[9.5px] font-mono uppercase tracking-wide flex-none px-1.5 py-0.5 rounded" style="color:{c};background:color-mix(in srgb,{c} 16%,transparent)">agent</span>{/if}
              </button>
            {/each}
          </div>
        </div>
      {/if}
      <textarea bind:this={ta} bind:value={draft} onkeydown={onKey} rows="1" placeholder="Reply…"
        class="w-full resize-none bg-card border border-line rounded-xl px-3.5 py-2.5 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]"></textarea>
    </div>
  </aside>
{/if}
