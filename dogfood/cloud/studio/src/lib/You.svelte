<script>
  // You — a WHOLE PAGE account view (not the settings overlay). Identity, appearance, and the agents
  // you own with their provable blast radius (the differentiator, surfaced where you manage yourself).
  import { ui, surfaces, assuranceFor, avatarOf, ME, setTheme } from './data.svelte.js'
  import { auth, logout } from './auth.svelte.js'
  import { iconSvgByName } from './icons.js'

  const me = $derived(auth.me || { name: 'You', email: 'you@demo', role: 'owner', org: 'demo' })
  const myAgents = $derived(surfaces.filter((s) => s.kind === 'agent'))

  const TIER_COLOR = { exfil: 'var(--color-bad)', execute: 'var(--color-fuchsia)', write: 'var(--color-peach)', network: 'var(--color-sky)', read: 'var(--color-mint)', none: 'var(--color-dim)' }
  const THEMES = [ { id: 'dark', label: 'Dark', icon: 'half-moon' }, { id: 'light', label: 'Light', icon: 'sun-light' } ]
</script>

<div class="h-full bg-paper flex flex-col min-w-0">
  <div class="flex items-center gap-3 px-6 h-[58px] flex-none border-b border-line">
    <div class="flex-1 min-w-0">
      <div class="font-display font-semibold text-[19px] tracking-tight leading-none">You</div>
      <div class="text-dim text-[12.5px] mt-1">Your account, appearance & the agents you own</div>
    </div>
  </div>

  <div class="flex-1 overflow-y-auto px-6 py-6">
    <div class="max-w-[720px] flex flex-col gap-6">
      <!-- identity -->
      <div class="flex items-center gap-4">
        <img src={avatarOf(ME, 'human')} alt={me.name} class="w-16 h-16 rounded-2xl object-cover border border-line" />
        <div class="min-w-0">
          <div class="font-display font-semibold text-[20px] leading-tight">{me.name}</div>
          <div class="text-dim text-[13px]">{me.email}</div>
          <div class="flex items-center gap-1.5 mt-1.5">
            <span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-card border border-line text-dim capitalize">{me.role}</span>
            <span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-card border border-line text-dim">org · {me.org}</span>
          </div>
        </div>
      </div>

      <!-- appearance -->
      <section>
        <div class="text-[11px] font-mono uppercase tracking-wider text-dim mb-2.5">Appearance</div>
        <div class="flex gap-2.5">
          {#each THEMES as t}
            <button onclick={() => setTheme(t.id)}
              class="flex items-center gap-2.5 rounded-xl border px-4 py-3 text-left transition [&>span>svg]:w-[16px] [&>span>svg]:h-[16px]"
              style="border-color:{ui.theme === t.id ? 'color-mix(in srgb,var(--color-sky) 60%,var(--color-line))' : 'var(--color-line)'};background:{ui.theme === t.id ? 'color-mix(in srgb,var(--color-sky) 10%,transparent)' : 'transparent'}">
              <span class="grid place-items-center text-dim">{@html iconSvgByName(t.icon, 16)}</span>
              <span class="text-[14px]">{t.label}</span>
              {#if ui.theme === t.id}<span class="text-[11px]" style="color:var(--color-mint)">●</span>{/if}
            </button>
          {/each}
        </div>
      </section>

      <!-- agents you own — each with its provable maximum blast radius -->
      <section>
        <div class="text-[11px] font-mono uppercase tracking-wider text-dim mb-2.5">Your agents · blast radius</div>
        <div class="flex flex-col gap-2.5">
          {#each myAgents as a}
            {@const r = assuranceFor(a.name)}
            <div class="rounded-xl border border-line bg-card p-3.5">
              <div class="flex items-center gap-2.5">
                <img src={avatarOf(a.name, 'agent')} alt={a.name} class="w-7 h-7 rounded-lg bg-paper border border-line" />
                <span class="font-semibold text-[14px] flex-1 min-w-0 truncate">{a.name}</span>
                <span class="px-2 py-0.5 rounded-md text-[10px] font-mono uppercase tracking-wider"
                  style="background:color-mix(in srgb,{TIER_COLOR[r.blast_radius.tier]} 16%,transparent);color:{TIER_COLOR[r.blast_radius.tier]}">{r.blast_radius.tier} tier</span>
              </div>
              <div class="text-dim text-[12.5px] mt-2 leading-snug">{r.summary}</div>
              <div class="flex flex-wrap gap-1.5 mt-2.5">
                {#each r.labels as l}
                  <span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim">{l}</span>
                {/each}
              </div>
            </div>
          {/each}
        </div>
      </section>

      <!-- sign out -->
      <section class="pt-1">
        <button onclick={logout}
          class="rounded-xl border border-line px-4 py-2.5 text-[13.5px] hover:bg-[color-mix(in_srgb,var(--color-bad)_10%,transparent)] hover:border-[color-mix(in_srgb,var(--color-bad)_40%,var(--color-line))] transition"
          style="color:var(--color-bad)">Sign out</button>
      </section>
    </div>
  </div>
</div>
