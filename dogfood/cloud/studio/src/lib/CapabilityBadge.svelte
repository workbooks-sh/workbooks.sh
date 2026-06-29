<script module>
  // edited grants, keyed by agent name — shared across all badge instances, preferred over the seed.
  const overrides = $state({})
</script>

<script>
  // The agent blast-radius badge — always-on in an agent's header. Shows a compact "can reach …"
  // summary + a tier dot; clicking opens the Capabilities panel: the explicit allow-list (grant/
  // revoke) and the plain-language ceiling ("this agent can, at most, X"). The differentiator made
  // visible — backed on the server by Nexus.AgentGov.assurance.
  import { assuranceFor, capLabel, capTier, blastRadius } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  // in-component override map, keyed by agent name. Since data.svelte.js can't be edited, edited
  // grants live here and are PREFERRED over the seeded budget when rendering an assurance.
  // (module-scope $state → shared across every CapabilityBadge instance, like the real store would be.)
  // assuranceFromBudget mirrors data.svelte.js assuranceFor, but for an arbitrary budget.
  function assuranceFromBudget(name, budget) {
    const r = blastRadius(budget)
    const verbs = [r.reads_secrets && 'read secrets', r.executes && 'run code', r.destructive && 'write data', r.network && 'reach the network'].filter(Boolean)
    return {
      name, budget, blast_radius: r,
      labels: budget.map((c) => capLabel(c)),
      summary: r.tier === 'none' ? `${name} can only read what you pass it.`
        : verbs.length ? `${name} can, at most, ${verbs.join(', ')} — and nothing beyond its budget.`
        : `${name} can, at most, perform read-only actions.`
    }
  }

  let { agent } = $props()
  let open = $state(false)
  let editing = $state(false)
  let draft = $state([]) // local editable copy of the budget while the grants editor is open

  // a reasonable capability catalog to toggle from
  const CATALOG = ['repo-read', 'exec', 'fs', 'db', 'net', 'secrets', 'browse', 'llm']

  // the base assurance from the store, then OVERLAY any saved override for this agent.
  const base = $derived(assuranceFor(agent))
  const a = $derived(overrides[agent] ? assuranceFromBudget(agent, overrides[agent]) : base)

  // tier → color (mirrors the danger ordering: exfil/execute hot, read cool)
  const TIER_COLOR = { exfil: 'var(--color-bad,#d66)', execute: 'var(--color-peach)', write: 'var(--color-amber,#d9a441)', network: 'var(--color-sky)', read: 'var(--color-mint)', none: 'var(--color-mint)' }
  const reach = $derived(a.labels.slice(0, 2).join(' · ') + (a.labels.length > 2 ? ` +${a.labels.length - 2}` : ''))

  // live blast radius computed from the in-flight draft, so the summary updates as you toggle.
  const draftReach = $derived(blastRadius(draft))

  function openEditor() { draft = [...a.budget]; editing = true }
  function toggle(cap) { draft = draft.includes(cap) ? draft.filter((c) => c !== cap) : [...draft, cap] }
  function save() { overrides[agent] = [...draft]; editing = false }
</script>

<div class="relative">
  <button onclick={() => (open = !open)} title="What this agent can touch"
    class="flex items-center gap-1.5 rounded-full border border-line px-2 py-0.5 text-[11px] text-dim hover:text-ink hover:border-[color-mix(in_srgb,var(--color-ink)_25%,var(--color-line))] transition [&>svg]:w-3 [&>svg]:h-3">
    <span class="w-2 h-2 rounded-full flex-none" style="background:{TIER_COLOR[a.blast_radius.tier]}"></span>
    {@html iconSvgByName('shield', 12)}
    <span class="max-w-[180px] truncate">can reach: {reach}</span>
  </button>

  {#if open}
    <div class="absolute top-8 right-0 z-30 w-[300px] rounded-xl border border-line bg-paper shadow-2xl overflow-hidden">
      <div class="px-3.5 py-3 border-b border-line">
        <div class="text-[10px] font-mono uppercase tracking-wider text-dim mb-1">Least-privilege assurance</div>
        <div class="text-[13px] text-ink leading-snug">{editing ? assuranceFromBudget(agent, draft).summary : a.summary}</div>
      </div>

      {#if editing}
        <!-- grant editor: toggle the catalog; the blast-radius summary above updates live -->
        <div class="p-2">
          {#each CATALOG as cap}
            {@const on = draft.includes(cap)}
            <button onclick={() => toggle(cap)}
              class="flex items-center gap-2.5 w-full px-2 py-1.5 text-[13px] rounded-lg hover:bg-[color-mix(in_srgb,var(--color-ink)_4%,transparent)]">
              <span class="w-3.5 h-3.5 rounded border flex-none grid place-items-center [&>svg]:w-3 [&>svg]:h-3"
                style="border-color:{on ? TIER_COLOR[capTier(cap)] : 'var(--color-line)'};background:{on ? TIER_COLOR[capTier(cap)] : 'transparent'};color:var(--color-paper)">
                {#if on}{@html iconSvgByName('check', 12)}{/if}
              </span>
              <span class="{on ? 'text-ink/85' : 'text-dim'}">{capLabel(cap)}</span>
              <span class="ml-auto text-[10px] font-mono uppercase text-dim">{capTier(cap)}</span>
            </button>
          {/each}
        </div>
        <div class="px-3.5 py-2.5 border-t border-line flex items-center justify-between">
          <span class="w-2 h-2 rounded-full flex-none" style="background:{TIER_COLOR[draftReach.tier]}" title="blast radius: {draftReach.tier}"></span>
          <div class="flex items-center gap-3">
            <button class="text-[12px] text-dim hover:text-ink" onclick={() => (editing = false)}>Cancel</button>
            <button class="text-[12px] font-medium" style="color:var(--color-sky)" onclick={save}>Save</button>
          </div>
        </div>
      {:else}
        <div class="p-2">
          {#each a.budget as c}
            <div class="flex items-center gap-2.5 px-2 py-1.5 text-[13px]">
              <span class="w-1.5 h-1.5 rounded-full flex-none" style="background:{TIER_COLOR[capTier(c)]}"></span>
              <span class="text-ink/85">{capLabel(c)}</span>
              <span class="ml-auto text-[10px] font-mono uppercase text-dim">{capTier(c)}</span>
            </div>
          {/each}
        </div>
        <div class="px-3.5 py-2.5 border-t border-line flex items-center justify-between">
          <span class="text-[11px] text-dim">Proven before it runs</span>
          <button class="text-[12px] font-medium" style="color:var(--color-sky)" onclick={openEditor}>Edit grants</button>
        </div>
      {/if}
    </div>
  {/if}
</div>
