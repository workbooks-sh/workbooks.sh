<script>
  import { tick } from 'svelte'
  import { send, runWorkflow, mentionCandidates, workflowsFor, SLASH, entityById, avatarOf, surfaces, assuranceFor } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  let { surfaceId } = $props()
  const surface = $derived(entityById(surfaceId))
  const ws = $derived(surface?.workspace)

  let draft = $state('')
  let attachments = $state([])
  let active = $state(0)
  let fileInput
  let ta

  // emoji popover — clicking an emoji appends it to the draft
  const EMOJI = ['👍', '👎', '🎉', '👀', '✅', '❤️', '🔥', '😄', '😂', '🙏', '👏', '💯',
    '🚀', '⭐', '💡', '🤔', '😅', '😎', '🙌', '👌', '💪', '🎯', '⚡', '✨',
    '🐛', '🛠️', '📌', '🚨', '😬', '🥳']
  let emojiOpen = $state(false)
  function insertEmoji(e) {
    draft = draft + e
    emojiOpen = false
    tick().then(() => ta?.focus())
  }

  // toolbar affordances → drop the trigger char in and focus, so the picker opens natively
  function trigger(ch) {
    if (ch === '/') draft = draft.trim() ? draft : '/'
    else draft = draft + (draft && !draft.endsWith(' ') ? ' ' : '') + ch
    tick().then(() => ta?.focus())
  }

  // pre-run preview: if the draft @-mentions an agent (a complete mention), show its blast radius so
  // the human sees "this will touch X" BEFORE summoning it — provable reach at the moment of action.
  const summoned = $derived.by(() => {
    const m = [...draft.matchAll(/@(\w+)/g)].map((x) => x[1].toLowerCase())
    if (!m.length) return null
    const agent = surfaces.find((s) => s.kind === 'agent' && m.includes(s.name.toLowerCase().replace(/\s+/g, '')))
    return agent ? assuranceFor(agent.name) : null
  })

  // grow the textarea with its content up to a cap, then it scrolls
  function autogrow() { if (!ta) return; ta.style.height = 'auto'; ta.style.height = Math.min(ta.scrollHeight, 192) + 'px' }
  $effect(() => { draft; autogrow() })

  // Which picker is open, and the filtered rows, derived purely from the draft text.
  const picker = $derived.by(() => {
    const cmd = draft.match(/^\/(\w*)$/) // leading slash, no space yet
    if (cmd) {
      const q = cmd[1].toLowerCase()
      const wfs = workflowsFor(ws).map((w) => ({ kind: 'workflow', name: w.name, icon: w.icon, hint: w.payload.steps.join(' → ') }))
      const rows = [...wfs, ...SLASH.map((c) => ({ kind: 'slash', name: c.name, icon: c.icon, hint: c.hint }))]
        .filter((r) => r.name.toLowerCase().startsWith(q))
      return { type: 'command', rows }
    }
    const men = draft.match(/(?:^|\s)@(\w*)$/) // trailing @token
    if (men) {
      const q = men[1].toLowerCase()
      const rows = mentionCandidates(ws).filter((r) => r.name.toLowerCase().startsWith(q))
      return { type: 'mention', rows }
    }
    return null
  })

  $effect(() => { if (picker) active = Math.min(active, Math.max(0, picker.rows.length - 1)) })

  function choose(row) {
    if (picker.type === 'mention') {
      draft = draft.replace(/(^|\s)@\w*$/, (m, pre) => `${pre}@${row.name} `)
    } else if (row.kind === 'workflow') {
      runWorkflow(surfaceId, workflowsFor(ws).find((w) => w.name === row.name)); draft = ''
    } else {
      draft = `/${row.name} `
    }
    active = 0
  }

  function submit() {
    send(surfaceId, draft, $state.snapshot(attachments))
    draft = ''; attachments = []
  }

  function onKey(e) {
    if (picker && picker.rows.length) {
      if (e.key === 'ArrowDown') { e.preventDefault(); active = (active + 1) % picker.rows.length; return }
      if (e.key === 'ArrowUp') { e.preventDefault(); active = (active - 1 + picker.rows.length) % picker.rows.length; return }
      if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); choose(picker.rows[active]); return }
      if (e.key === 'Escape') { draft = draft.replace(/(^|\s)@\w*$/, '$1').replace(/^\/\w*$/, ''); return }
    }
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit() }
  }

  function addFiles(list) {
    for (const f of list) {
      const isImg = f.type.startsWith('image/')
      attachments.push({ type: isImg ? 'image' : 'file', name: f.name,
        size: `${Math.max(1, Math.round(f.size / 1024))} KB`,
        url: isImg ? URL.createObjectURL(f) : null, color: '#c8e0b0' })
    }
  }
  const onPaste = (e) => { const f = [...(e.clipboardData?.files || [])]; if (f.length) { e.preventDefault(); addFiles(f) } }
  const onDrop = (e) => { e.preventDefault(); addFiles(e.dataTransfer.files) }
</script>

<div class="px-4 py-3 relative">
  <!-- pre-run blast-radius preview: shown when an agent is @-mentioned in the draft -->
  {#if summoned}
    <div class="mb-2 flex items-center gap-2 rounded-lg px-3 py-1.5 text-[12px] [&>svg]:w-3.5 [&>svg]:h-3.5"
      style="background:color-mix(in srgb,var(--color-sky) 9%,transparent);color:color-mix(in srgb,var(--color-ink) 80%,transparent)">
      {@html iconSvgByName('shield', 13)}
      <span><b>{summoned.name}</b> will be able to: {summoned.labels.join(', ')} — and nothing else.</span>
    </div>
  {/if}
  <!-- @ / picker — a floating card spanning the composer, kind-colored rows -->
  {#if picker && picker.rows.length}
    <div class="absolute bottom-full left-4 right-4 mb-2 rounded-2xl border border-line bg-card overflow-hidden z-20"
      style="box-shadow:0 20px 48px rgba(0,0,0,.4)">
      <div class="flex items-center gap-1.5 px-3 py-1.5 text-[10px] font-mono uppercase tracking-widest text-dim border-b border-line [&>svg]:w-3 [&>svg]:h-3">
        {@html iconSvgByName(picker.type === 'mention' ? 'at-sign' : 'terminal', 12)}
        {picker.type === 'mention' ? 'Mention a person or agent' : 'Run a workflow or command'}
      </div>
      <div class="max-h-[260px] overflow-y-auto py-1">
        {#each picker.rows as r, i}
          {@const c = r.kind === 'agent' ? 'var(--color-fuchsia)' : r.kind === 'workflow' ? 'var(--color-peach)' : 'var(--color-dim)'}
          <button class="flex items-center gap-2.5 w-full text-left px-3 py-2 {i === active ? 'bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)]' : ''} hoverwash"
            onmouseenter={() => (active = i)} onclick={() => choose(r)}>
            {#if r.kind === 'person'}
              <img src={avatarOf(r.name, 'human')} alt={r.name} class="w-6 h-6 rounded-md object-cover flex-none border border-line" />
            {:else}
              <span class="w-6 h-6 flex-none grid place-items-center rounded-md [&>svg]:w-[15px] [&>svg]:h-[15px]"
                style="color:{c};background:color-mix(in srgb,{c} 16%,transparent)">{@html iconSvgByName(r.icon || (r.kind === 'agent' ? 'cpu' : r.kind === 'workflow' ? 'git-fork' : 'sparks'), 15)}</span>
            {/if}
            <span class="font-medium text-[13.5px] flex-none"><span class="text-dim">{picker.type === 'command' ? '/' : '@'}</span>{r.name}</span>
            {#if r.hint}<span class="text-dim/70 text-[11.5px] truncate flex-1 text-right font-mono">{r.hint}</span>{/if}
            {#if r.kind === 'agent' || r.kind === 'workflow'}<span class="text-[9.5px] font-mono uppercase tracking-wide flex-none px-1.5 py-0.5 rounded" style="color:{c};background:color-mix(in srgb,{c} 16%,transparent)">{r.kind}</span>{/if}
          </button>
        {/each}
      </div>
    </div>
  {/if}

  <!-- the composer card: multiline textarea above an extensible inline toolbar -->
  <div class="rounded-2xl border border-line bg-card transition-colors
      focus-within:border-[color-mix(in_srgb,var(--color-sky)_65%,var(--color-line))]"
    ondrop={onDrop} ondragover={(e) => e.preventDefault()}>

    <!-- staged attachments -->
    {#if attachments.length}
      <div class="flex flex-wrap gap-2 px-3 pt-3">
        {#each attachments as a, i}
          <div class="flex items-center gap-2 pl-1 pr-2 py-1 rounded-lg border border-line bg-paper">
            {#if a.type === 'image' && a.url}
              <img src={a.url} alt={a.name} class="w-7 h-7 rounded object-cover" />
            {:else}
              <span class="w-7 h-7 rounded grid place-items-center [&>svg]:w-[14px] [&>svg]:h-[14px]"
                style="background:color-mix(in srgb,var(--color-sky) 30%,transparent);color:var(--color-ink)">{@html iconSvgByName('empty-page', 14)}</span>
            {/if}
            <span class="text-[12.5px] max-w-[120px] truncate">{a.name}</span>
            <button class="text-dim hover:text-ink grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]" onclick={() => attachments.splice(i, 1)}>{@html iconSvgByName('xmark', 13)}</button>
          </div>
        {/each}
      </div>
    {/if}

    <textarea bind:this={ta} bind:value={draft} onkeydown={onKey} onpaste={onPaste} rows="1"
      placeholder={`Message ${surface?.name}…`}
      class="w-full resize-none bg-transparent px-3.5 pt-3 pb-1.5 max-h-48 focus:outline-none text-[14.5px] leading-relaxed placeholder:text-dim/70"></textarea>

    <!-- inline toolbar — the extensible action row -->
    <div class="flex items-center gap-0.5 px-2 pb-2 relative">
      <!-- emoji popover -->
      {#if emojiOpen}
        <div class="absolute bottom-full left-2 mb-2 z-30 grid grid-cols-8 gap-0.5 rounded-xl border border-line bg-paper shadow-lg p-1.5 w-[232px]">
          {#each EMOJI as e}<button onclick={() => insertEmoji(e)} class="text-[16px] grid place-items-center h-7 rounded hover:bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)] hover:scale-110 transition">{e}</button>{/each}
        </div>
      {/if}
      {#each [['attachment', 'Attach a file', () => fileInput.click()], ['at-sign', 'Mention (@)', () => trigger('@')], ['terminal', 'Run a workflow (/)', () => trigger('/')], ['emoji', 'Emoji', () => (emojiOpen = !emojiOpen)]] as [name, label, fn]}
        <button title={label} aria-label={label} onclick={fn}
          class="w-8 h-8 grid place-items-center rounded-lg text-dim hover:text-ink hoverwash [&>svg]:w-[17px] [&>svg]:h-[17px]">{@html iconSvgByName(name, 17)}</button>
      {/each}
      <div class="w-px h-5 bg-line mx-1"></div>
      <button title="More — extensible" class="w-8 h-8 grid place-items-center rounded-lg text-dim/55 hover:text-ink hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('plus', 15)}</button>

      <span class="flex-1"></span>
      <span class="hidden sm:block text-dim/50 text-[10.5px] font-mono mr-1.5">⏎ send · ⇧⏎ newline</span>
      <button onclick={submit} aria-label="Send" title="Send"
        class="w-9 h-8 grid place-items-center rounded-lg transition-colors [&>svg]:w-[16px] [&>svg]:h-[16px]
          {draft.trim() || attachments.length ? 'bg-ink text-paper' : 'bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)] text-dim'}">{@html iconSvgByName('arrow-up', 16)}</button>
    </div>
  </div>

  <input type="file" multiple bind:this={fileInput} class="hidden" onchange={(e) => { addFiles(e.target.files); e.target.value = '' }} />
</div>
