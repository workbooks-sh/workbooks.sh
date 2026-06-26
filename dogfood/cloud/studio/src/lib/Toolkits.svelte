<script>
  // Toolkits — the catalog page. A toolkit is a CLI compiled to WASM + its bundled skills; enabling one
  // adds its tools to every sandbox in the nexus. Rows come from the registry (toolkits.svelte.js);
  // icons resolve through our glyphs toolkit; the sub-nav (ToolkitsNav) drives the filter (connected /
  // all / a category). Each card carries the language, capability tier, WASM-port status and auth.
  import { ui } from './data.svelte.js'
  import { toolkits, enabledToolkits, toolkitsInCategory, markFor, capsOf, CAP_META, LANG_META, AUTH_META, connState } from './toolkits.svelte.js'
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

  const MAX_TOOLS = 4 // chips shown on a card before the +N pill (full list lives in the detail drawer)
  function toggle(t) { t.enabled = !t.enabled } // connecting (auth) is a separate, explicit step

  // open the right surface for an integration that needs access: a secrets modal (env) or the login terminal (oauth)
  function connect(t) {
    if (t.auth === 'env') ui.secretsModal = t.id
    else if (t.auth === 'oauth') ui.authTerminal = t.id
  }
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
          {@const cs = connState(t)}
          <div class="group rounded-2xl border border-line bg-card p-4 flex flex-col gap-3 transition"
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
                  {#if t.lang}
                    <span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none" style="color:{lang.tint};border:1px solid color-mix(in srgb,{lang.tint} 40%,transparent)">{lang.label}</span>
                  {/if}
                  <!-- how it authenticates: env (credentials) or oauth (CLI login). none ⇒ no badge. -->
                  {#if AUTH_META[t.auth]}
                    <span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none text-dim border border-line">{AUTH_META[t.auth].badge}</span>
                  {/if}
                </div>
                <div class="text-dim text-[12.5px] mt-1 leading-snug">{t.summary}</div>
              </div>
              <div class="flex items-center gap-1.5 flex-none">
                <!-- details: appears on hover, opens the right-side drawer (WASI grant, hosts, file types, risk) -->
                <button onclick={() => (ui.toolkitDetail = t.id)} title="Details"
                  class="w-6 h-6 grid place-items-center rounded-md text-dim hover:text-ink border border-transparent hover:border-line opacity-0 group-hover:opacity-100 transition [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('info-circle', 14)}</button>
                <!-- enable toggle -->
                <button onclick={() => toggle(t)} title={t.enabled ? 'Disable' : 'Enable'}
                  class="w-9 h-5 rounded-full relative transition" style="background:{t.enabled ? 'var(--color-mint)' : 'var(--color-line)'}">
                  <span class="absolute top-0.5 w-4 h-4 rounded-full bg-paper transition-all" style="left:{t.enabled ? '18px' : '2px'}"></span>
                </button>
              </div>
            </div>

            <!-- a CLI has many subcommands — show a few, then a +N pill that opens the full list in details -->
            <div class="flex flex-wrap gap-1.5">
              {#each t.tools.slice(0, MAX_TOOLS) as tool}<span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim">{tool}</span>{/each}
              {#if t.tools.length > MAX_TOOLS}
                <button onclick={() => (ui.toolkitDetail = t.id)} title="See all {t.tools.length} commands"
                  class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim hover:text-ink hover:border-[color-mix(in_srgb,var(--color-ink)_30%,var(--color-line))] transition">+{t.tools.length - MAX_TOOLS}</button>
              {/if}
            </div>

            <div class="flex items-end gap-2 mt-auto pt-1">
              <!-- the sandbox capability grant as compact colour badges (read/write/network/spawn) -->
              <div class="flex items-center flex-wrap gap-1.5 flex-1">
                {#each capsOf(t) as cap}
                  <span class="px-1.5 py-0.5 rounded text-[10px] font-mono leading-none"
                    style="color:{CAP_META[cap].color};background:color-mix(in srgb,{CAP_META[cap].color} 14%,transparent)">{CAP_META[cap].label}</span>
                {/each}
              </div>
              <!-- bottom-right connection action — only once enabled and the toolkit needs access -->
              {#if t.enabled && (cs.needs || cs.ok)}
                {#if cs.ok}
                  <button onclick={() => connect(t)} title="Connected — manage"
                    class="flex-none flex items-center gap-1 px-2 py-1 rounded-lg text-[11px] border transition [&>svg]:w-3 [&>svg]:h-3"
                    style="color:var(--color-mint);border-color:color-mix(in srgb,var(--color-mint) 35%,transparent);background:color-mix(in srgb,var(--color-mint) 10%,transparent)">{@html iconSvgByName('check', 12)}{cs.label}</button>
                {:else}
                  <button onclick={() => connect(t)}
                    class="flex-none flex items-center gap-1 px-2 py-1 rounded-lg text-[11px] border transition [&>svg]:w-3 [&>svg]:h-3"
                    style="color:var(--color-peach);border-color:color-mix(in srgb,var(--color-peach) 40%,transparent);background:color-mix(in srgb,var(--color-peach) 12%,transparent)">{@html iconSvgByName('warning-triangle', 12)}{cs.label}</button>
                {/if}
              {/if}
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
