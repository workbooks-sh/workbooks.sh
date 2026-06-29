<script>
  // Create flow for the global "+" menu. Two modes:
  //  · kind === 'workspace' → name + access scope, then addWorkspace
  //  · kind is a surface kind → name + DESTINATION (workspace + optional folder), then addSurface
  // The contextual "+"s (on a workspace / folder) skip this — they already know where the thing goes.
  import { workspaces, foldersFor, addSurface, addWorkspace, surfaceById, ui } from './data.svelte.js'
  import { iconSvgByName, KIND_COLOR } from './icons.js'

  let { kind, onClose } = $props()
  const isWs = $derived(kind === 'workspace')

  const KIND_LABEL = { chat: 'Channel', agent: 'Agent', workflow: 'Workflow', app: 'App', database: 'Database' }
  const KIND_ICON = { chat: 'chat-bubble', agent: 'cpu', workflow: 'git-fork', app: 'app-window', database: 'database' }
  const SCOPES = [
    { id: 'shared', label: 'Shared', hint: 'Everyone in the org', icon: 'globe' },
    { id: 'private', label: 'Private', hint: 'You or a small team', icon: 'lock' },
    { id: 'admin', label: 'Admin', hint: 'Root · org-wide control', icon: 'shield' }
  ]

  let name = $state('')
  let scope = $state('shared')
  let wsId = $state(ui.workspace)
  let folderId = $state('')

  const folders = $derived(isWs ? [] : foldersFor(wsId))
  const ok = $derived(isWs ? true : !!wsId) // name optional → falls back to a sensible default

  function submit() {
    if (isWs) {
      addWorkspace(name.trim() || 'New workspace', scope)
    } else {
      const s = addSurface(kind, wsId, folderId || null)
      if (name.trim()) s.name = name.trim()
    }
    onClose()
  }
  const inputCls = 'w-full bg-paper border border-line rounded-lg px-3 py-2 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_60%,var(--color-line))]'
  const lblCls = 'text-[10.5px] uppercase tracking-wide text-dim mb-1.5 font-mono'
</script>

<div class="fixed inset-0 z-[80] grid place-items-center" style="background:rgba(0,0,0,.45)" role="presentation"
  onclick={onClose}>
  <div class="w-[420px] max-w-[92vw] rounded-2xl border border-line bg-card overflow-hidden" style="box-shadow:0 30px 70px rgba(0,0,0,.5)"
    role="dialog" tabindex="-1" onclick={(e) => e.stopPropagation()}>
    <div class="flex items-center gap-2.5 px-4 py-3 border-b border-line">
      <span class="grid place-items-center [&>svg]:w-[17px] [&>svg]:h-[17px]" style="color:{isWs ? 'var(--color-ink)' : KIND_COLOR[kind]}">{@html iconSvgByName(isWs ? 'folder-plus' : KIND_ICON[kind], 17)}</span>
      <span class="font-display font-semibold text-[15px]">New {isWs ? 'workspace' : KIND_LABEL[kind]}</span>
      <span class="flex-1"></span>
      <button class="text-dim hover:text-ink grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]" onclick={onClose}>{@html iconSvgByName('xmark', 16)}</button>
    </div>

    <div class="p-4 flex flex-col gap-4">
      <div>
        <div class={lblCls}>Name</div>
        <!-- svelte-ignore a11y_autofocus -->
        <input bind:value={name} autofocus class={inputCls}
          placeholder={isWs ? 'e.g. Marketing' : `e.g. ${KIND_LABEL[kind].toLowerCase()}-name`}
          onkeydown={(e) => e.key === 'Enter' && ok && submit()} />
      </div>

      {#if isWs}
        <div>
          <div class={lblCls}>Access scope</div>
          <div class="flex flex-col gap-1.5">
            {#each SCOPES as sc}
              <button onclick={() => (scope = sc.id)}
                class="flex items-center gap-2.5 w-full text-left px-3 py-2 rounded-lg border {scope === sc.id ? 'border-[color-mix(in_srgb,var(--color-sky)_60%,var(--color-line))] bg-[color-mix(in_srgb,var(--color-ink)_5%,transparent)]' : 'border-line hoverwash'}">
                <span class="grid place-items-center text-dim [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName(sc.icon, 15)}</span>
                <span class="flex-1"><span class="text-[13.5px] font-medium">{sc.label}</span> <span class="text-dim text-[12px]">· {sc.hint}</span></span>
                <span class="w-[15px] h-[15px] rounded-full border grid place-items-center {scope === sc.id ? 'border-[var(--color-sky)]' : 'border-line'}">
                  {#if scope === sc.id}<span class="w-[8px] h-[8px] rounded-full" style="background:var(--color-sky)"></span>{/if}
                </span>
              </button>
            {/each}
          </div>
        </div>
      {:else}
        <div>
          <div class={lblCls}>Workspace</div>
          <select bind:value={wsId} class={inputCls} onchange={() => (folderId = '')}>
            {#each workspaces as w}<option value={w.id}>{w.name}</option>{/each}
          </select>
        </div>
        {#if folders.length}
          <div>
            <div class={lblCls}>Folder <span class="normal-case text-dim/60">(optional)</span></div>
            <select bind:value={folderId} class={inputCls}>
              <option value="">— top level —</option>
              {#each folders as f}<option value={f.id}>{f.name}</option>{/each}
            </select>
          </div>
        {/if}
      {/if}
    </div>

    <div class="flex items-center justify-end gap-2 px-4 py-3 border-t border-line">
      <button class="text-[13px] px-3 py-2 rounded-lg text-dim hover:text-ink hoverwash" onclick={onClose}>Cancel</button>
      <button disabled={!ok} onclick={submit}
        class="text-[13px] font-medium px-3.5 py-2 rounded-lg {ok ? 'bg-ink text-paper' : 'text-dim/50 cursor-not-allowed'}">Create</button>
    </div>
  </div>
</div>
