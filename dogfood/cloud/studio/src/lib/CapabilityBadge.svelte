<script>
  // The agent blast-radius badge — always-on in an agent's header. Shows a compact "can reach …"
  // summary + a tier dot; clicking opens the Capabilities panel: the explicit allow-list (grant/
  // revoke) and the plain-language ceiling ("this agent can, at most, X"). The differentiator made
  // visible — backed on the server by Nexus.AgentGov.assurance.
  import { assuranceFor, capLabel, capTier } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  let { agent } = $props()
  let open = $state(false)
  const a = $derived(assuranceFor(agent))

  // tier → color (mirrors the danger ordering: exfil/execute hot, read cool)
  const TIER_COLOR = { exfil: 'var(--color-bad,#d66)', execute: 'var(--color-peach)', write: 'var(--color-amber,#d9a441)', network: 'var(--color-sky)', read: 'var(--color-mint)', none: 'var(--color-mint)' }
  const reach = $derived(a.labels.slice(0, 2).join(' · ') + (a.labels.length > 2 ? ` +${a.labels.length - 2}` : ''))
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
        <div class="text-[13px] text-ink leading-snug">{a.summary}</div>
      </div>
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
        <button class="text-[12px] font-medium" style="color:var(--color-sky)">Edit grants</button>
      </div>
    </div>
  {/if}
</div>
