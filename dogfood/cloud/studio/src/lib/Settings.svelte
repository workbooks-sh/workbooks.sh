<script>
  import { ui, surfaceById, workspaces } from './data.svelte.js'
  const s = $derived(surfaceById(ui.surfaceId))
  const fieldCls = 'text-[11px] uppercase tracking-wide text-dim mb-1 font-mono'
  const inputCls = 'w-full bg-card border border-line rounded-lg px-2.5 py-[7px] focus:outline-none focus:border-bloom'
</script>

{#if s}
  <div class="fixed top-0 right-0 h-screen w-[340px] bg-paper border-l border-line p-[18px] z-30"
    style="box-shadow:-20px 0 40px rgba(0,0,0,.35)">
    <button class="float-right text-dim hover:text-ink text-lg" onclick={() => (ui.settingsOpen = false)}>×</button>
    <h3 class="font-display text-lg font-semibold">{s.icon} {s.name}</h3>
    <div class="text-dim text-[12.5px] mb-4">Settings — shared across every kind ({s.kind})</div>

    <div class="mb-3.5"><div class={fieldCls}>Name</div><input class={inputCls} bind:value={s.name} /></div>
    <div class="mb-3.5"><div class={fieldCls}>Icon / emoji</div><input class={inputCls} bind:value={s.icon} /></div>
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
    {/if}
    {#if s.kind === 'workflow'}
      <div class="mb-3.5"><div class={fieldCls}>Steps</div>
        <div class="text-dim text-[11.5px]">{s.payload.steps.join(' → ')}</div></div>
    {/if}
  </div>
{/if}
