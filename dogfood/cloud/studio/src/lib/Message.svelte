<script>
  import { avatarOf, openAuthor, toggleReaction, replyCount, ME } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'
  let { m, onOpenThread } = $props()
  const av = $derived(avatarOf(m.author, m.kind))
  // people & agents are clickable: people open a profile card, agents jump to their surface
  const clickable = $derived(m.kind === 'human' || m.kind === 'agent')

  // split text into plain runs and @mention chips
  const parts = $derived((m.text || '').split(/(@\w+)/).map((v) => ({ mention: v.startsWith('@'), v })))

  // reactions + threads (the wired leaf actions). hover reveals the quick-react / reply affordances.
  const QUICK = ['👍', '🎉', '👀', '✅', '❤️']
  let hover = $state(false)
  let picking = $state(false)
  const replies = $derived(replyCount(m.id))
  function react(emoji) { toggleReaction(m.id, emoji); picking = false }
</script>

{#if m.kind === 'workflow-run'}
  <!-- a workflow running inline in the chat -->
  <div class="flex gap-2.5">
    <div class="w-7 h-7 rounded-[7px] flex-none grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]"
      style="background:color-mix(in srgb,var(--color-peach) 45%,transparent);color:var(--color-ink)">{@html iconSvgByName('git-fork', 15)}</div>
    <div class="min-w-0 flex-1 max-w-md">
      <div class="flex gap-2 items-baseline">
        <span class="font-semibold">/{m.run.workflow}</span>
        <span class="text-dim text-[11px] font-mono">{m.ts}</span>
        <span class="text-[10px] font-mono uppercase text-dim">{m.run.status}</span>
      </div>
      <div class="mt-1.5 rounded-lg border border-line bg-card p-2.5 flex flex-col gap-1.5">
        {#each m.run.steps as st}
          <div class="flex items-center gap-2.5 text-[13px]">
            <span class="w-2.5 h-2.5 rounded-full flex-none"
              style="background:{st.status === 'done' ? 'var(--color-mint)' : 'var(--color-line)'};
                {st.status !== 'done' ? 'box-shadow:0 0 0 3px color-mix(in srgb,var(--color-peach) 30%,transparent)' : ''}"></span>
            <span class={st.status === 'done' ? 'text-ink' : 'text-dim'}>{st.name}</span>
            {#if st.status === 'done'}<span class="ml-auto" style="color:var(--color-mint)">✓</span>{/if}
          </div>
        {/each}
      </div>
    </div>
  </div>
{:else}
  <div class="flex gap-2.5" role="group" onmouseenter={() => (hover = true)} onmouseleave={() => { hover = false; picking = false }}>
    {#if av}
      <img src={av} alt={m.author} onclick={() => clickable && openAuthor(m.author, m.kind)}
        class="w-7 h-7 rounded-[7px] flex-none object-cover border border-line bg-card {clickable ? 'cursor-pointer hover:ring-2 hover:ring-[color-mix(in_srgb,var(--color-ink)_18%,transparent)] transition-shadow' : ''}" />
    {:else}
      <div class="w-7 h-7 rounded-[7px] flex-none grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]"
        style="background:color-mix(in srgb,var(--color-mint) 45%,transparent);color:var(--color-ink)">{@html iconSvgByName('bell', 15)}</div>
    {/if}
    <div class="min-w-0 flex-1">
      <div class="flex gap-2 items-baseline">
        <span class="font-semibold {clickable ? 'cursor-pointer hover:underline' : ''}"
          onclick={() => clickable && openAuthor(m.author, m.kind)}>{m.author}</span>
        {#if m.kind === 'agent'}<span class="text-[10px] font-mono" style="color:var(--color-mint)">agent</span>{/if}
        <span class="text-dim text-[11px] font-mono">{m.ts}</span>
      </div>
      {#if m.text}
        <div class="whitespace-pre-wrap text-ink/90">{#each parts as p}{#if p.mention}<span class="font-medium rounded px-1 py-0.5" style="color:var(--color-ink);background:color-mix(in srgb,var(--color-sky) 28%,transparent)">{p.v}</span>{:else}{p.v}{/if}{/each}</div>
      {/if}

      {#if m.attachments?.length}
        <div class="mt-2 flex flex-wrap gap-2">
          {#each m.attachments as a}
            {#if a.type === 'image'}
              <!-- native aspect: show at intrinsic size, capped to a sensible max box -->
              <img src={a.url} alt={a.name} width={a.w} height={a.h}
                class="rounded-lg border border-line w-auto h-auto max-w-[min(440px,100%)] max-h-[340px] object-contain" />
            {:else}
              <div class="flex items-center gap-2.5 px-3 py-2 rounded-lg border border-line bg-card max-w-xs">
                <span class="w-8 h-8 rounded grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]"
                  style="background:color-mix(in srgb,var(--color-sky) 35%,transparent);color:var(--color-ink)">{@html iconSvgByName('empty-page', 15)}</span>
                <div class="min-w-0">
                  <div class="text-[13px] font-medium truncate">{a.name}</div>
                  {#if a.size}<div class="text-dim text-[11px]">{a.size}</div>{/if}
                </div>
                <button class="ml-auto text-dim hover:text-ink grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('download', 15)}</button>
              </div>
            {/if}
          {/each}
        </div>
      {/if}

      <!-- reactions row: existing reactions as toggle chips + a hover quick-react / reply affordance -->
      {#if m.reactions?.length || replies > 0 || hover}
        <div class="mt-1.5 flex items-center gap-1.5 flex-wrap">
          {#each m.reactions || [] as r}
            <button onclick={() => react(r.emoji)}
              class="flex items-center gap-1 rounded-full border px-1.5 py-0.5 text-[12px] transition"
              style="border-color:{r.by.includes(ME) ? 'color-mix(in srgb,var(--color-sky) 60%,var(--color-line))' : 'var(--color-line)'};
                background:{r.by.includes(ME) ? 'color-mix(in srgb,var(--color-sky) 18%,transparent)' : 'transparent'}">
              <span>{r.emoji}</span><span class="text-dim tabular-nums">{r.by.length}</span>
            </button>
          {/each}

          {#if replies > 0}
            <button onclick={() => onOpenThread?.(m)}
              class="flex items-center gap-1 text-[12px] text-dim hover:text-ink [&>svg]:w-3 [&>svg]:h-3">
              {@html iconSvgByName('chat-bubble', 12)} {replies} {replies === 1 ? 'reply' : 'replies'}
            </button>
          {/if}

          {#if hover}
            <div class="relative flex items-center">
              <button onclick={() => (picking = !picking)} aria-label="Add reaction"
                class="text-dim hover:text-ink grid place-items-center [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('emoji', 14)}</button>
              {#if onOpenThread}
                <button onclick={() => onOpenThread(m)} aria-label="Reply in thread"
                  class="ml-1 text-dim hover:text-ink grid place-items-center [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('reply', 14)}</button>
              {/if}
              {#if picking}
                <div class="absolute bottom-6 left-0 z-10 flex gap-1 rounded-lg border border-line bg-paper shadow-lg px-1.5 py-1">
                  {#each QUICK as e}<button onclick={() => react(e)} class="text-[15px] hover:scale-125 transition">{e}</button>{/each}
                </div>
              {/if}
            </div>
          {/if}
        </div>
      {/if}
    </div>
  </div>
{/if}
