<script>
  // Toolkits — the catalog page. A toolkit is a CLI compiled to WASM + its bundled skills; enabling one
  // adds its tools to every sandbox in the nexus. Rows come from the registry (toolkits.svelte.js);
  // icons resolve through our glyphs toolkit; the sub-nav (ToolkitsNav) drives the filter (connected /
  // all / a category). Each card carries the language, capability tier, WASM-port status and auth.
  import { ui } from './data.svelte.js'
  import { toolkits, enabledToolkits, toolkitsInCategory, markFor, capsOf, CAP_META, LANG_META, AUTH_META } from './toolkits.svelte.js'
  import Glyph from './Glyph.svelte'
  import { iconSvgByName } from './icons.js'

  const view = $derived(ui.toolkitsView)
  const shown = $derived(
    view === 'connected' ? enabledToolkits() :
    view === 'all' ? toolkits : toolkitsInCategory(view)
  )
  const title = $derived(view === 'connected' ? 'Connected' : view === 'all' ? 'All toolkits' : view)
  const sub = $derived(
    view === 'connected' ? 'CLIs enabled in your sandboxes — available to every agent & flow' :
    view === 'all' ? 'Every CLI in the registry — a CLI compiled to WASM, shipped with its skills' :
    `${view} toolkits`)

  function toggle(t) { t.enabled = !t.enabled; if (t.kind === 'integration' && t.enabled) t.connected = true }
</script>

<div class="h-full bg-paper flex flex-col min-w-0">
  <div class="flex items-center gap-3 px-6 pt-6 pb-4 flex-none border-b border-line">
    <div class="flex-1 min-w-0">
      <div class="font-display font-semibold text-[19px] tracking-tight leading-none">{title}</div>
      <div class="text-dim text-[12.5px] mt-1.5">{sub} · {shown.length} {shown.length === 1 ? 'toolkit' : 'toolkits'}</div>
    </div>
  </div>

  <div class="flex-1 overflow-y-auto px-6 py-6">
    {#if !shown.length}
      <div class="text-dim/70 text-[13.5px]">Nothing here yet. Browse the catalog and enable a toolkit to make its CLI available to your agents.</div>
    {:else}
      <div class="grid gap-3.5 max-w-[980px]" style="grid-template-columns:repeat(auto-fill,minmax(300px,1fr))">
        {#each shown as t (t.id)}
          {@const lang = LANG_META[t.lang] || { label: t.lang, tint: 'var(--color-dim)' }}
          {@const mk = markFor(t)}
          <div class="rounded-2xl border border-line bg-card p-4 flex flex-col gap-3 transition"
            style="border-color:{t.enabled ? 'color-mix(in srgb,var(--color-mint) 32%,var(--color-line))' : 'var(--color-line)'}">
            <div class="flex items-start gap-3">
              <!-- a clean simple-icon tinted by its hand-assigned brand colour (markFor), on the paper tile.
                   Neutral marks (GitHub/Vercel) tint to --color-ink so they stay legible in either theme;
                   a CLI with no brand mark falls back to its language icon, tinted with the language colour. -->
              <span class="w-9 h-9 rounded-xl grid place-items-center flex-none border border-line bg-paper [&_svg]:w-[18px] [&_svg]:h-[18px]">
                <Glyph ref={mk.ref} color={mk.color} size={18} fallback={t.fallback} />
              </span>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2">
                  <span class="font-semibold text-[14px] truncate">{t.name}</span>
                  <span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none" style="color:{lang.tint};border:1px solid color-mix(in srgb,{lang.tint} 40%,transparent)">{lang.label}</span>
                </div>
                <div class="text-dim text-[12.5px] mt-1 leading-snug">{t.summary}</div>
              </div>
              <!-- enable toggle -->
              <button onclick={() => toggle(t)} title={t.enabled ? 'Disable' : 'Enable'}
                class="flex-none w-9 h-5 rounded-full relative transition" style="background:{t.enabled ? 'var(--color-mint)' : 'var(--color-line)'}">
                <span class="absolute top-0.5 w-4 h-4 rounded-full bg-paper transition-all" style="left:{t.enabled ? '18px' : '2px'}"></span>
              </button>
            </div>

            <div class="flex flex-wrap gap-1.5">
              {#each t.tools as tool}<span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim">{tool}</span>{/each}
            </div>

            <div class="flex items-center flex-wrap gap-x-1.5 gap-y-1 mt-auto pt-1 text-[11px]">
              <!-- the sandbox capability grant, plain language + cumulative (derived from WASI imports in prod) -->
              {#each capsOf(t) as cap, i}
                {#if i > 0}<span class="text-dim/40">·</span>{/if}
                <span class="flex items-center gap-1" style="color:{CAP_META[cap].color}"><span class="w-1.5 h-1.5 rounded-full" style="background:{CAP_META[cap].color}"></span>{CAP_META[cap].label}</span>
              {/each}
              {#if t.kind === 'integration'}
                <span class="text-dim/40">·</span>
                <span class="text-dim flex items-center gap-1 [&>svg]:w-[11px] [&>svg]:h-[11px]">{@html iconSvgByName('lock', 11)}{AUTH_META[t.auth]?.label || t.auth}{#if t.connected}<span style="color:var(--color-mint)"> · connected</span>{/if}</span>
              {/if}
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
