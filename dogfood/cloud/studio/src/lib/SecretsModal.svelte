<script>
  // Secrets modal — for env/API-key toolkits. Lists the credentials the CLI needs (one or several), lets you
  // paste values, and pick a scope (just me / org / admin-locked). On save the values go to the secret vault
  // (in production: the org-scoped encrypted env store, Nexus.Secrets — never source/.work) and the toolkit
  // flips to connected. The scope selector seeds the personal/org/admin policy structure we'll formalise later.
  import { ui } from './data.svelte.js'
  import { toolkits, secretVault, SCOPES, markFor, LANG_META } from './toolkits.svelte.js'
  import Glyph from './Glyph.svelte'
  import { iconSvgByName } from './icons.js'

  const t = $derived(toolkits.find((x) => x.id === ui.secretsModal))
  const mk = $derived(t ? markFor(t) : null)
  const keys = $derived(t?.secrets || [])

  // local draft, seeded from any already-stored values (so re-opening shows what's set)
  let scope = $state('personal')
  let vals = $state({})
  $effect(() => {
    if (!t) return
    const saved = secretVault[t.id]
    scope = saved?.scope || 'personal'
    vals = { ...(saved?.values || {}) }
  })

  const ready = $derived(keys.length > 0 && keys.every((k) => (vals[k] || '').trim()))

  function close() { ui.secretsModal = null }
  function save() {
    if (!ready) return
    secretVault[t.id] = { scope, values: { ...vals } }
    t.connected = true
    close()
  }
  function onKey(e) { if (e.key === 'Escape') close() }
</script>

<svelte:window onkeydown={onKey} />

{#if t}
  <div class="fixed inset-0 z-50 grid place-items-center p-4">
    <button class="absolute inset-0 bg-black/45" aria-label="Close" onclick={close}></button>
    <div class="relative w-[min(460px,94vw)] rounded-2xl border border-line bg-paper shadow-2xl flex flex-col max-h-[88vh]">
      <header class="flex items-center gap-3 px-4 py-3.5 border-b border-line flex-none">
        <span class="w-8 h-8 rounded-lg grid place-items-center flex-none border border-line bg-card [&_svg]:w-[17px] [&_svg]:h-[17px]">
          <Glyph ref={mk.ref} color={mk.color} size={17} fallback={t.fallback} />
        </span>
        <div class="flex-1 min-w-0">
          <div class="font-display font-semibold text-[15px] leading-tight">Connect {t.name}</div>
          <div class="text-dim text-[11.5px]">Stored as encrypted env secrets · never written to source</div>
        </div>
        <button aria-label="Close" onclick={close}
          class="w-8 h-8 grid place-items-center text-dim hover:text-ink rounded-lg border border-line [&>svg]:w-4 [&>svg]:h-4">{@html iconSvgByName('xmark', 16)}</button>
      </header>

      <div class="px-4 py-4 overflow-y-auto flex flex-col gap-4">
        <div class="flex flex-col gap-3">
          {#each keys as k}
            <label class="flex flex-col gap-1.5">
              <span class="text-[11px] font-mono text-dim">{k}</span>
              <input bind:value={vals[k]} type="password" autocomplete="off" spellcheck="false" placeholder="paste value…"
                class="w-full bg-card border border-line rounded-lg px-3 py-2 text-[13px] font-mono focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
            </label>
          {/each}
        </div>

        <div class="flex flex-col gap-1.5">
          <span class="text-[10px] font-mono uppercase tracking-widest text-dim/70">Who can use this</span>
          <div class="grid grid-cols-3 gap-1.5">
            {#each SCOPES as s}
              <button onclick={() => (scope = s.id)} title={s.detail}
                class="px-2 py-2 rounded-lg border text-[12px] text-left transition"
                style="border-color:{scope === s.id ? 'color-mix(in srgb,var(--color-sky) 55%,var(--color-line))' : 'var(--color-line)'};background:{scope === s.id ? 'color-mix(in srgb,var(--color-sky) 12%,transparent)' : 'transparent'}">
                <span class="font-medium block leading-tight">{s.label}</span>
              </button>
            {/each}
          </div>
          <span class="text-dim text-[11.5px] leading-snug">{SCOPES.find((s) => s.id === scope)?.detail}</span>
        </div>
      </div>

      <footer class="px-4 py-3 border-t border-line flex items-center gap-2 flex-none">
        <span class="text-dim text-[11px] flex-1 flex items-center gap-1 [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('lock', 13)}Encrypted at rest</span>
        <button onclick={close} class="px-3 py-1.5 rounded-lg text-[12.5px] text-dim hover:text-ink border border-line transition">Cancel</button>
        <button onclick={save} disabled={!ready}
          class="px-3 py-1.5 rounded-lg text-[12.5px] font-medium transition disabled:opacity-40"
          style="background:var(--color-mint);color:var(--color-paper)">Save & connect</button>
      </footer>
    </div>
  </div>
{/if}
