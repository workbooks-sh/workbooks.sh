<script>
  // Provider detail — the manage drawer for a multi-connection provider. Mirrors ToolkitDetail's shape: an
  // overview line, then sections. The core section is Connections (each variant has its own enable toggle +
  // connect action: env → secrets modal, oauth → login terminal). Below it, the union of the sandbox
  // capability grant and network hosts across the connections, so the provider reads like a single detail panel.
  import { ui } from './data.svelte.js'
  import { providerById, variantType, markFor, capsOf, CAP_META, AUTH_META, connState } from './toolkits.svelte.js'
  import Glyph from './Glyph.svelte'
  import { iconSvgByName } from './icons.js'

  const p = $derived(providerById(ui.providerDetail))
  const mk = $derived(p ? markFor(p.rep) : null)
  const enabledCount = $derived(p ? p.variants.filter((v) => v.enabled).length : 0)
  // union of capabilities + hosts across every connection (capsOf orders a provider's aggregated caps)
  const allCaps = $derived(p ? capsOf(p) : [])
  const allHosts = $derived.by(() => {
    if (!p) return []
    return [...new Set(p.variants.flatMap((v) => v.hosts || []))]
  })

  function close() { ui.providerDetail = null }
  function onKey(e) { if (e.key === 'Escape') close() }
  function toggle(v) { v.enabled = !v.enabled }
  function connect(v) {
    if (v.auth === 'env') ui.secretsModal = v.id
    else if (v.auth === 'oauth') ui.authTerminal = v.id
  }
</script>

<svelte:window onkeydown={onKey} />

{#if p}
  <button class="fixed inset-0 z-30 bg-black/30" aria-label="Close" onclick={close}></button>
  <aside class="fixed top-0 right-0 h-screen w-[min(440px,94vw)] z-40 bg-paper border-l border-line shadow-2xl flex flex-col">
    <header class="flex items-center gap-3 px-4 h-[57px] border-b border-line flex-none">
      <span class="w-8 h-8 rounded-lg grid place-items-center flex-none border border-line bg-card overflow-hidden [&_svg]:w-[19px] [&_svg]:h-[19px]">
        <Glyph ref={mk.ref} color={mk.color} ink={mk.ink} size={17} fallback={p.rep.fallback} />
      </span>
      <div class="flex-1 min-w-0">
        <div class="font-display font-semibold text-[15px] truncate">{p.name}</div>
        <div class="text-dim text-[11.5px] truncate">{p.variants.length} connections · {p.category}</div>
      </div>
      <button aria-label="Close" onclick={close}
        class="w-8 h-8 grid place-items-center text-dim hover:text-ink rounded-lg border border-line [&>svg]:w-4 [&>svg]:h-4">{@html iconSvgByName('xmark', 16)}</button>
    </header>

    <div class="flex-1 overflow-y-auto px-4 py-4 flex flex-col gap-5">
      <p class="text-[13.5px] text-dim leading-relaxed">{p.name} groups {p.variants.length} connections — each a CLI compiled to WASM that authenticates independently. Enable the ones you need; {enabledCount} {enabledCount === 1 ? 'is' : 'are'} on.</p>

      <section>
        <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Connections · {enabledCount}/{p.variants.length} on</div>
        <div class="flex flex-col gap-2">
          {#each p.variants as v (v.id)}
            {@const cs = connState(v)}
            <div class="rounded-xl border border-line p-2.5 flex flex-col gap-2.5"
              style="border-color:{v.enabled ? 'color-mix(in srgb,var(--color-mint) 30%,var(--color-line))' : 'var(--color-line)'}">
              <div class="flex items-center gap-2.5">
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="font-medium text-[13.5px] truncate">{variantType(v, p.name)}</span>
                    {#if AUTH_META[v.auth]}<span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none text-dim border border-line">{AUTH_META[v.auth].badge}</span>{/if}
                  </div>
                  <div class="flex items-center flex-wrap gap-1.5 mt-1.5">
                    {#each capsOf(v) as cap}
                      <span class="px-1.5 py-0.5 rounded text-[10px] font-mono leading-none" style="color:{CAP_META[cap].color};background:color-mix(in srgb,{CAP_META[cap].color} 14%,transparent)">{CAP_META[cap].label}</span>
                    {/each}
                    {#each v.hosts || [] as h}<span class="px-1.5 py-0.5 rounded text-[10px] font-mono leading-none text-dim/80 bg-card border border-line">{h}</span>{/each}
                  </div>
                </div>
                <button onclick={() => toggle(v)} title={v.enabled ? 'Disable' : 'Enable'}
                  class="flex-none w-9 h-5 rounded-full relative transition" style="background:{v.enabled ? 'var(--color-mint)' : 'var(--color-line)'}">
                  <span class="absolute top-0.5 w-4 h-4 rounded-full bg-paper transition-all" style="left:{v.enabled ? '18px' : '2px'}"></span>
                </button>
              </div>
              {#if v.enabled && (cs.needs || cs.ok)}
                <button onclick={() => connect(v)}
                  class="self-start flex items-center gap-1 px-2 py-1 rounded-lg text-[11px] border transition [&>svg]:w-3 [&>svg]:h-3"
                  style="color:{cs.ok ? 'var(--color-mint)' : 'var(--color-peach)'};border-color:color-mix(in srgb,{cs.ok ? 'var(--color-mint)' : 'var(--color-peach)'} 38%,transparent);background:color-mix(in srgb,{cs.ok ? 'var(--color-mint)' : 'var(--color-peach)'} 11%,transparent)">{@html iconSvgByName(cs.ok ? 'check' : 'warning-triangle', 12)}{cs.label}</button>
              {/if}
            </div>
          {/each}
        </div>
      </section>

      {#if allCaps.length}
        <section>
          <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Sandbox capabilities · WASI grant</div>
          <div class="flex flex-col gap-2">
            {#each allCaps as cap}
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

      {#if allHosts.length}
        <section>
          <div class="text-[10px] font-mono uppercase tracking-widest text-dim/70 mb-2">Network hosts</div>
          <div class="flex flex-col gap-1.5">
            {#each allHosts as h}
              <div class="flex items-center gap-2 text-[12.5px] font-mono text-ink [&>svg]:w-3.5 [&>svg]:h-3.5 [&>svg]:text-[var(--color-sky)]">{@html iconSvgByName('globe', 14)}{h}</div>
            {/each}
          </div>
        </section>
      {/if}
    </div>
  </aside>
{/if}
