<script>
  import { ui, surfaceById, surfacesFor, workspaces, changeWorkspaceScope, assuranceFor } from './data.svelte.js'
  import { iconSvg, KIND_COLOR } from './icons.js'
  import IconPicker from './IconPicker.svelte'
  const s = $derived(surfaceById(ui.surfaceId))
  const ws = $derived(workspaces.find((w) => w.id === ui.wsSettings))
  const fieldCls = 'text-[11px] uppercase tracking-wide text-dim mb-1 font-mono'
  const inputCls = 'w-full bg-card border border-line rounded-lg px-2.5 py-[7px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_60%,var(--color-line))]'
  let pickerOpen = $state(false)
  let wsPickerOpen = $state(false)
  const close = () => { ui.settingsOpen = false; ui.wsSettings = null }
</script>

{#if ws}
  <!-- WORKSPACE settings (opened via the gear on a workspace header) -->
  <div class="fixed top-0 right-0 h-screen w-[340px] bg-paper border-l border-line p-[18px] z-30"
    style="box-shadow:-20px 0 40px rgba(0,0,0,.35)">
    <button class="float-right text-dim hover:text-ink text-lg" onclick={close}>×</button>
    <h3 class="font-display text-lg font-semibold flex items-center gap-2">
      <span class="grid place-items-center text-dim [&>svg]:w-[18px] [&>svg]:h-[18px]">{@html iconSvg(ws.icon)}</span>
      {ws.name}
    </h3>
    <div class="text-dim text-[12.5px] mb-4">Workspace settings · groups your channels, apps, agents & data</div>

    <div class="mb-3.5"><div class={fieldCls}>Name</div><input class={inputCls} bind:value={ws.name} /></div>

    <div class="mb-3.5">
      <div class={fieldCls}>Icon</div>
      <button onclick={() => (wsPickerOpen = true)}
        class="flex items-center gap-2.5 w-full bg-card border border-line rounded-lg px-2.5 py-2 hoverwash">
        <span class="grid place-items-center text-dim [&>svg]:w-[18px] [&>svg]:h-[18px]">{@html iconSvg(ws.icon)}</span>
        <span class="text-[13.5px] flex-1 text-left">{ws.icon}</span>
        <span class="text-dim text-[12px]">Change…</span>
      </button>
    </div>

    <div class="mb-3.5">
      <div class={fieldCls}>Visibility</div>
      {#if ws.personal}
        <div class="text-dim text-[12.5px]">Private — only you</div>
      {:else}
        <select class={inputCls} value={ws.scope === 'private' ? 'private' : 'shared'}
          onchange={(e) => changeWorkspaceScope(ws.id, e.target.value)}>
          <option value="shared">Shared — everyone in the org</option>
          <option value="private">Private — a small group</option>
        </select>
      {/if}
    </div>

    <div class="mb-3.5">
      <div class={fieldCls}>Contents</div>
      <div class="text-dim text-[12.5px]">{surfacesFor(ws.id).length} items in this workspace</div>
    </div>
  </div>

  {#if wsPickerOpen}
    <IconPicker value={ws.icon} color={'var(--color-dim)'}
      onpick={(k) => { ws.icon = k; wsPickerOpen = false }} onclose={() => (wsPickerOpen = false)} />
  {/if}
{:else if s}
  <div class="fixed top-0 right-0 h-screen w-[340px] bg-paper border-l border-line p-[18px] z-30"
    style="box-shadow:-20px 0 40px rgba(0,0,0,.35)">
    <button class="float-right text-dim hover:text-ink text-lg" onclick={close}>×</button>
    <h3 class="font-display text-lg font-semibold flex items-center gap-2">
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR[s.kind]}">{@html iconSvg(s.icon, s.kind)}</span>
      {s.name}
    </h3>
    <div class="text-dim text-[12.5px] mb-4">Settings — shared across every kind ({s.kind})</div>

    <div class="mb-3.5"><div class={fieldCls}>Name</div><input class={inputCls} bind:value={s.name} /></div>

    <div class="mb-3.5">
      <div class={fieldCls}>Icon — color is fixed by kind ({s.kind})</div>
      <button onclick={() => (pickerOpen = true)}
        class="flex items-center gap-2.5 w-full bg-card border border-line rounded-lg px-2.5 py-2 hoverwash">
        <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR[s.kind]}">{@html iconSvg(s.icon, s.kind)}</span>
        <span class="text-[13.5px] flex-1 text-left">{s.icon}</span>
        <span class="text-dim text-[12px]">Change…</span>
      </button>
    </div>
    <div class="mb-3.5"><div class={fieldCls}>Purpose</div><input class={inputCls} bind:value={s.purpose} placeholder="What this is for" /></div>

    <div class="mb-3.5">
      <div class={fieldCls}>Workspace (access)</div>
      <select class={inputCls} bind:value={s.workspace}>
        {#each workspaces as w}<option value={w.id}>{w.name}</option>{/each}
      </select>
      <div class="text-dim text-[11.5px] mt-1">Access = everyone in this workspace (v1 model).</div>
    </div>

    <div class="mb-3.5">
      <div class={fieldCls}>Private</div>
      <select class={inputCls} value={s.private ? 'yes' : 'no'} onchange={(e) => (s.private = e.target.value === 'yes')}>
        <option value="no">No — visible to workspace</option>
        <option value="yes">Yes — only me (personal)</option>
      </select>
    </div>

    {#if s.kind === 'app'}
      <div class="mb-3.5"><div class={fieldCls}>Pages (from the app block)</div>
        <div class="text-dim text-[11.5px]">{s.payload.pages.map((p) => p.label).join(', ')}</div></div>
    {/if}
    {#if s.kind === 'agent'}
      <div class="mb-3.5"><div class={fieldCls}>Model</div><input class={inputCls} bind:value={s.payload.model} /></div>

      <!-- VOLUMES — the agent's attached data stores (memory, embeddings, caches) -->
      <div class="mb-3.5">
        <div class={fieldCls}>Volumes</div>
        <div class="flex flex-col gap-1.5">
          {#each (s.payload.volumes ||= []) as v, i}
            <div class="flex items-center gap-2 bg-card border border-line rounded-lg px-2.5 py-[7px]">
              <input class="bg-transparent flex-1 min-w-0 focus:outline-none text-[13px]" bind:value={v.name} />
              <input class="bg-transparent w-16 text-[11px] font-mono text-dim focus:outline-none" bind:value={v.format} />
              <span class="text-[11px] font-mono text-dim/70">{v.rows} rows</span>
              <button title="Remove volume" class="text-dim hover:text-[var(--color-bad,#d66)] grid place-items-center [&>svg]:w-3.5 [&>svg]:h-3.5"
                onclick={() => s.payload.volumes.splice(i, 1)}>{@html iconSvg('xmark')}</button>
            </div>
          {/each}
        </div>
        <button class="mt-1.5 text-[12px] flex items-center gap-1 [&>svg]:w-3 [&>svg]:h-3" style="color:var(--color-sky)"
          onclick={() => (s.payload.volumes ||= []).push({ name: 'new-volume', format: 'sqlite', rows: 0 })}>{@html iconSvg('plus')} Add volume</button>
      </div>

      <!-- CAPABILITY SUMMARY — least-privilege assurance; grants editable from the badge -->
      <div class="mb-3.5">
        <div class={fieldCls}>Capabilities</div>
        <div class="text-[12.5px] text-ink/85 leading-snug">{assuranceFor(s.name).summary}</div>
        <div class="text-dim text-[11.5px] mt-1">Edit grants from the capability badge in the agent header.</div>
      </div>
    {/if}
    {#if s.kind === 'workflow'}
      <!-- STEPS — ordered list, each editable; add/remove -->
      <div class="mb-3.5">
        <div class={fieldCls}>Steps</div>
        <div class="flex flex-col gap-1.5">
          {#each (s.payload.steps ||= []) as _, i}
            <div class="flex items-center gap-2">
              <span class="text-[11px] font-mono text-dim/60 w-4 text-right">{i + 1}</span>
              <input class={inputCls} bind:value={s.payload.steps[i]} />
              <button title="Remove step" class="text-dim hover:text-[var(--color-bad,#d66)] grid place-items-center [&>svg]:w-3.5 [&>svg]:h-3.5"
                onclick={() => s.payload.steps.splice(i, 1)}>{@html iconSvg('xmark')}</button>
            </div>
          {/each}
        </div>
        <button class="mt-1.5 text-[12px] flex items-center gap-1 [&>svg]:w-3 [&>svg]:h-3" style="color:var(--color-sky)"
          onclick={() => (s.payload.steps ||= []).push('New step')}>{@html iconSvg('plus')} Add step</button>
      </div>

      <!-- INPUTS — the trigger form fields ({key,label,type}); add/remove/rename -->
      <div class="mb-3.5">
        <div class={fieldCls}>Inputs</div>
        <div class="flex flex-col gap-1.5">
          {#each (s.payload.inputs ||= []) as inp, i}
            <div class="flex items-center gap-2 bg-card border border-line rounded-lg px-2.5 py-[7px]">
              <input class="bg-transparent w-20 text-[11px] font-mono text-dim focus:outline-none" bind:value={inp.key} placeholder="key" />
              <input class="bg-transparent flex-1 min-w-0 focus:outline-none text-[13px]" bind:value={inp.label} placeholder="Label" />
              <input class="bg-transparent w-14 text-[11px] font-mono text-dim focus:outline-none" bind:value={inp.type} placeholder="text" />
              <button title="Remove input" class="text-dim hover:text-[var(--color-bad,#d66)] grid place-items-center [&>svg]:w-3.5 [&>svg]:h-3.5"
                onclick={() => s.payload.inputs.splice(i, 1)}>{@html iconSvg('xmark')}</button>
            </div>
          {/each}
        </div>
        <button class="mt-1.5 text-[12px] flex items-center gap-1 [&>svg]:w-3 [&>svg]:h-3" style="color:var(--color-sky)"
          onclick={() => (s.payload.inputs ||= []).push({ key: 'field', label: 'New input', type: 'text' })}>{@html iconSvg('plus')} Add input</button>
      </div>
    {/if}
  </div>

  {#if pickerOpen}
    <IconPicker value={s.icon} color={KIND_COLOR[s.kind]}
      onpick={(k) => { s.icon = k; pickerOpen = false }} onclose={() => (pickerOpen = false)} />
  {/if}
{/if}
