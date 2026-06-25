<script>
  let { m } = $props()
  const initials = (a) => a.slice(0, 2).toUpperCase()

  // split text into plain runs and @mention chips
  const parts = $derived((m.text || '').split(/(@\w+)/).map((v) => ({ mention: v.startsWith('@'), v })))

  const avBg = m.kind === 'agent' ? 'linear-gradient(135deg,var(--color-violet),var(--color-blue))'
    : m.kind === 'system' ? 'linear-gradient(135deg,var(--color-mint),var(--color-sage))'
    : 'linear-gradient(135deg,var(--color-peach),var(--color-cream))'
</script>

{#if m.kind === 'workflow-run'}
  <!-- a workflow running inline in the chat -->
  <div class="flex gap-2.5">
    <div class="w-7 h-7 rounded-[7px] flex-none grid place-items-center" style="background:linear-gradient(135deg,var(--color-cream),var(--color-peach))">🚦</div>
    <div class="min-w-0 flex-1 max-w-md">
      <div class="flex gap-2 items-baseline">
        <span class="font-semibold">/{m.run.workflow}</span>
        <span class="text-dim text-[11px] font-mono">{m.ts}</span>
        <span class="text-[10px] font-mono uppercase {m.run.status === 'done' ? 'text-bloomd' : 'text-amber'}">{m.run.status}</span>
      </div>
      <div class="mt-1.5 rounded-lg border border-line bg-card p-2.5 flex flex-col gap-1.5">
        {#each m.run.steps as s}
          <div class="flex items-center gap-2.5 text-[13px]">
            <span class="w-2.5 h-2.5 rounded-full flex-none"
              style="background:{s.status === 'done' ? 'var(--color-bloom)' : 'var(--color-line)'};
                {s.status !== 'done' ? 'box-shadow:0 0 0 3px color-mix(in srgb,var(--color-amber) 25%,transparent)' : ''}"></span>
            <span class={s.status === 'done' ? 'text-ink' : 'text-dim'}>{s.name}</span>
            {#if s.status === 'done'}<span class="text-bloomd text-xs ml-auto">✓</span>{/if}
          </div>
        {/each}
      </div>
    </div>
  </div>
{:else}
  <div class="flex gap-2.5">
    <div class="w-7 h-7 rounded-[7px] flex-none grid place-items-center text-[13px] font-bold font-mono text-[#10120f]" style="background:{avBg}">
      {m.kind === 'system' ? '🛎️' : initials(m.author)}
    </div>
    <div class="min-w-0 flex-1">
      <div class="flex gap-2 items-baseline">
        <span class="font-semibold {m.kind === 'agent' ? 'text-pause' : m.kind === 'system' ? 'text-bloomd' : ''}">{m.author}</span>
        <span class="text-dim text-[11px] font-mono">{m.ts}</span>
      </div>
      {#if m.text}
        <div class="whitespace-pre-wrap text-ink/90">{#each parts as p}{#if p.mention}<span class="text-pause font-medium bg-[color-mix(in_srgb,var(--color-pause)_15%,transparent)] rounded px-1 py-0.5">{p.v}</span>{:else}{p.v}{/if}{/each}</div>
      {/if}

      {#if m.attachments?.length}
        <div class="mt-2 flex flex-wrap gap-2">
          {#each m.attachments as a}
            {#if a.type === 'image'}
              <div class="w-44 h-28 rounded-lg border border-line overflow-hidden grid place-items-center"
                style="background:{a.url ? 'transparent' : `color-mix(in srgb,${a.color} 50%,transparent)`}">
                {#if a.url}<img src={a.url} alt={a.name} class="w-full h-full object-cover" />{:else}<span class="text-dim text-[11px]">{a.name}</span>{/if}
              </div>
            {:else}
              <div class="flex items-center gap-2.5 px-3 py-2 rounded-lg border border-line bg-card max-w-xs">
                <span class="w-8 h-8 rounded grid place-items-center" style="background:color-mix(in srgb,var(--color-sky) 35%,transparent)">📄</span>
                <div class="min-w-0">
                  <div class="text-[13px] font-medium truncate">{a.name}</div>
                  {#if a.size}<div class="text-dim text-[11px]">{a.size}</div>{/if}
                </div>
                <button class="ml-auto text-dim hover:text-ink text-xs">↓</button>
              </div>
            {/if}
          {/each}
        </div>
      {/if}
    </div>
  </div>
{/if}
