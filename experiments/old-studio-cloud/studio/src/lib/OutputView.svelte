<script>
  // renders one run output richly — used in the inline right-hand panel. kind ∈ doc | chat | data | app.
  import { iconSvgByName } from './icons.js'
  import { avatarOf } from './data.svelte.js'
  let { output } = $props()
</script>

<div class="px-5 py-5">
  {#if output.kind === 'doc'}
    <article class="flex flex-col gap-2.5">
      {#each output.body as b}
        {#if b.h}<h3 class="font-display font-semibold text-[16px] mt-2">{b.h}</h3>
        {:else if b.li}<div class="flex gap-2 text-[13.5px] text-ink/85"><span class="text-dim">•</span><span>{b.li}</span></div>
        {:else}<p class="text-[13.5px] leading-relaxed text-ink/85">{b.p}</p>{/if}
      {/each}
    </article>

  {:else if output.kind === 'chat'}
    <div class="flex flex-col gap-3">
      {#each output.messages as m}
        <div class="flex gap-2.5">
          <img src={avatarOf(m.author, 'agent')} alt={m.author} class="w-7 h-7 rounded-lg flex-none" style="background:var(--color-card)" />
          <div class="min-w-0">
            <div class="text-[12.5px] font-semibold">{m.author}</div>
            <div class="text-[13.5px] text-ink/85">{m.text}</div>
          </div>
        </div>
      {/each}
    </div>

  {:else if output.kind === 'data'}
    <div class="rounded-xl border border-line overflow-hidden">
      <table class="w-full text-[13px]">
        <thead><tr class="text-dim text-[11px] font-mono uppercase tracking-wider">
          {#each output.cols as c}<th class="text-left px-3 py-2 border-b border-line font-medium">{c}</th>{/each}
        </tr></thead>
        <tbody>
          {#each output.rows as row}
            <tr>{#each row as cell, i}<td class="px-3 py-2 border-b border-line/60 {i === 1 ? 'font-medium' : ''}" style={i === 1 ? 'color:var(--color-mint)' : ''}>{cell}</td>{/each}</tr>
          {/each}
        </tbody>
      </table>
    </div>

  {:else if output.kind === 'app'}
    <div class="rounded-xl border border-line bg-paper overflow-hidden">
      <div class="flex items-center gap-2 px-3 h-9 border-b border-line text-dim text-[12px] [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('app-window', 14)} {output.title}</div>
      <div class="p-6 flex flex-col gap-2.5">
        {#each [90, 70, 80, 55] as w}<div class="h-3 rounded" style="width:{w}%;background:color-mix(in srgb,var(--color-ink) 8%,transparent)"></div>{/each}
      </div>
    </div>
  {/if}
</div>
