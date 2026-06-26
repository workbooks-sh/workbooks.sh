<script>
  // Toolkit detail — the right-side drawer that opens from a card. Shows the deep facts behind a toolkit:
  // the sandbox capability grant mapped to its WASI imports, the network hosts it may reach, the file types
  // it works with, and a risk read-out derived from the capabilities. Slides in like the thread/media panels.
  import { ui } from './data.svelte.js'
  import { toolkits, markFor, capsOf, risksOf, CAP_META, LANG_META } from './toolkits.svelte.js'
  import Glyph from './Glyph.svelte'
  import { iconSvgByName } from './icons.js'

  const t = $derived(toolkits.find((x) => x.id === ui.toolkitDetail))
  const mk = $derived(t ? markFor(t) : null)
  const lang = $derived(t ? LANG_META[t.lang] || { label: t.lang, tint: 'var(--color-dim)' } : null)

  function close() { ui.toolkitDetail = null }
  function onKey(e) { if (e.key === 'Escape') close() }
</script>

<svelte:window onkeydown={onKey} />

{#if t}
  <!-- click-catcher so clicking the page closes the drawer -->
  <button class="fixed inset-0 z-30 bg-black/30" aria-label="Close" onclick={close}></button>
  <aside class="fixed top-0 right-0 h-screen w-[min(440px,94vw)] z-40 bg-paper border-l border-line shadow-2xl flex flex-col">
    <header class="flex items-center gap-3 px-4 h-[57px] border-b border-line flex-none">
      <span class="w-8 h-8 rounded-lg grid place-items-center flex-none border border-line bg-card overflow-hidden [&_svg]:w-[19px] [&_svg]:h-[19px]">
        <Glyph ref={mk.ref} color={mk.color} ink={mk.ink} size={17} fallback={t.fallback} />
      </span>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="font-display font-semibold text-[15px] truncate">{t.name}</span>
          {#if t.lang}<span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none" style="color:{lang.tint};border:1px solid color-mix(in srgb,{lang.tint} 40%,transparent)">{lang.label}</span>{/if}
        </div>
        <div class="text-dim text-[11.5px] truncate">{t.kind === 'integration' ? 'integration · needs a connection' : t.kind === 'skill' ? 'skill · context only, no executable' : 'tool · no auth'}</div>
      </div>
      <button aria-label="Close" onclick={close}
        class="w-8 h-8 grid place-items-center text-dim hover:text-ink rounded-lg border border-line [&>svg]:w-4 [&>svg]:h-4">{@html iconSvgByName('xmark', 16)}</button>
    </header>

    <div class="flex-1 overflow-y-auto px-4 py-4 flex flex-col gap-5">
      <p class="text-[13.5px] text-dim leading-relaxed">{t.summary}</p>

      <!-- A toolkit is a CLI compiled to WASM; it can only touch what the sandbox grants, and that grant maps
           1:1 to the module's WASI imports. We show the grant + the exact imports behind each capability. -->
      {#if capsOf(t).length}
      <section>
        <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Sandbox capabilities · WASI grant</div>
        <div class="flex flex-col gap-2">
          {#each capsOf(t) as cap}
            {@const m = CAP_META[cap]}
            <div class="rounded-xl border border-line p-2.5 flex items-start gap-2.5">
              <span class="w-1.5 h-1.5 rounded-full mt-1.5 flex-none" style="background:{m.color}"></span>
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <span class="text-[13px] font-medium" style="color:{m.color}">{m.label}</span>
                  <code class="text-[10.5px] font-mono text-dim/80 truncate">{m.wasi}</code>
                </div>
                <div class="text-dim text-[12px] mt-0.5 leading-snug">{m.detail}</div>
              </div>
            </div>
          {/each}
        </div>
      </section>
      {/if}

      {#if t.kind === 'skill'}
        <section>
          <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Skill</div>
          <div class="flex items-start gap-2 text-[12.5px] text-dim leading-snug [&>svg]:w-3.5 [&>svg]:h-3.5 [&>svg]:mt-0.5 [&>svg]:flex-none">{@html iconSvgByName('sparks', 14)}Pure context (a SKILL.md prompt pack) — loaded into the agent, runs no code and needs no sandbox grant.</div>
        </section>
      {/if}

      {#if t.hosts?.length}
        <section>
          <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Network hosts</div>
          <div class="flex flex-col gap-1.5">
            {#each t.hosts as h}
              <div class="flex items-center gap-2 text-[12.5px] font-mono text-ink [&>svg]:w-3.5 [&>svg]:h-3.5 [&>svg]:text-[var(--color-sky)]">{@html iconSvgByName('globe', 14)}{h}</div>
            {/each}
          </div>
        </section>
      {/if}

      {#if t.fileTypes?.length}
        <section>
          <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">File types</div>
          <div class="flex flex-wrap gap-1.5">
            {#each t.fileTypes as f}<span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-card border border-line text-dim">{f}</span>{/each}
          </div>
        </section>
      {/if}

      {#if t.tools?.length}
      <section>
        <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Commands · {t.tools.length}</div>
        <div class="flex flex-wrap gap-1.5">
          {#each t.tools as tool}<span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-card border border-line text-dim">{tool}</span>{/each}
        </div>
      </section>
      {/if}

      {#if t.kind !== 'skill'}
      <section>
        <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Risk</div>
        <div class="flex flex-col gap-1.5">
          {#each risksOf(t) as r}
            <div class="flex items-start gap-2 text-[12.5px] text-dim leading-snug [&>svg]:w-3.5 [&>svg]:h-3.5 [&>svg]:mt-0.5 [&>svg]:flex-none">{@html iconSvgByName('shield-alert', 14)}{r}</div>
          {/each}
        </div>
      </section>
      {/if}
    </div>
  </aside>
{/if}
