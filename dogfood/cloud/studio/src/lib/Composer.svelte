<script>
  import { send, runWorkflow, mentionCandidates, workflowsFor, SLASH, surfaceById } from './data.svelte.js'
  import { ICO } from './icons.js'

  let { surfaceId } = $props()
  const surface = $derived(surfaceById(surfaceId))
  const ws = $derived(surface?.workspace)

  let draft = $state('')
  let attachments = $state([])
  let active = $state(0)
  let fileInput

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

<div class="px-4 py-3 border-t border-line relative">
  <!-- @ / picker -->
  {#if picker && picker.rows.length}
    <div class="absolute bottom-full left-4 mb-2 w-80 rounded-xl border border-line bg-card overflow-hidden z-20"
      style="box-shadow:0 18px 40px rgba(0,0,0,.35)">
      <div class="px-3 py-1.5 text-[10px] font-mono uppercase tracking-widest text-dim border-b border-line">
        {picker.type === 'mention' ? 'Mention' : 'Run a workflow / command'}
      </div>
      {#each picker.rows as r, i}
        <button class="flex items-center gap-2.5 w-full text-left px-3 py-2 {i === active ? 'bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)]' : ''} hoverwash"
          onmouseenter={() => (active = i)} onclick={() => choose(r)}>
          <span class="w-5 text-center">{r.icon || (r.kind === 'agent' ? '🤖' : r.kind === 'person' ? '👤' : '/')}</span>
          <span class="font-semibold text-[13.5px]">{picker.type === 'command' ? '/' : '@'}{r.name}</span>
          {#if r.hint}<span class="text-dim text-[11.5px] truncate flex-1">{r.hint}</span>{/if}
          {#if r.kind === 'agent'}<span class="text-[10px] font-mono text-pause">agent</span>{/if}
        </button>
      {/each}
    </div>
  {/if}

  <!-- staged attachments -->
  {#if attachments.length}
    <div class="flex flex-wrap gap-2 mb-2">
      {#each attachments as a, i}
        <div class="flex items-center gap-2 pl-1 pr-2 py-1 rounded-lg border border-line bg-card">
          {#if a.type === 'image' && a.url}
            <img src={a.url} alt={a.name} class="w-7 h-7 rounded object-cover" />
          {:else}
            <span class="w-7 h-7 rounded grid place-items-center text-xs" style="background:color-mix(in srgb,{a.color} 35%,transparent)">📄</span>
          {/if}
          <span class="text-[12.5px] max-w-[120px] truncate">{a.name}</span>
          <button class="text-dim hover:text-bad text-sm" onclick={() => attachments.splice(i, 1)}>×</button>
        </div>
      {/each}
    </div>
  {/if}

  <div class="flex items-end gap-2 bg-card border border-line rounded-xl px-2 py-1.5
      focus-within:border-[color-mix(in_srgb,var(--color-bloom)_60%,var(--color-line))]"
    ondrop={onDrop} ondragover={(e) => e.preventDefault()}>
    <button class="flex-none w-8 h-8 grid place-items-center rounded-lg text-dim hover:text-ink hoverwash"
      title="Attach" onclick={() => fileInput.click()}>{@html ICO.plus}</button>
    <textarea bind:value={draft} onkeydown={onKey} onpaste={onPaste} rows="1"
      placeholder={`Message ${surface?.name} — @ to mention, / to run a workflow`}
      class="flex-1 resize-none bg-transparent py-1.5 max-h-40 focus:outline-none"></textarea>
    <button class="flex-none px-3 h-8 rounded-lg text-[12px] font-mono uppercase tracking-wider font-bold
        {draft.trim() || attachments.length ? 'bg-ink text-paper' : 'text-dim'}" onclick={submit}>Send</button>
  </div>
  <input type="file" multiple bind:this={fileInput} class="hidden" onchange={(e) => { addFiles(e.target.files); e.target.value = '' }} />
  <div class="text-dim text-[11px] mt-1.5">@-mention a person or agent · /run a workflow · drag, paste, or + to attach · no inbox</div>
</div>
