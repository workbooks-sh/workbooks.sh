<script>
  // Toolkits — a WHOLE PAGE (not a popover). A toolkit is a composable wasm CLI kit the runtime
  // exposes to agents & flows; enabling one adds its tools to every sandbox in the nexus. The kits
  // are demo data here; live, they'd resolve from the `toolkit` kinds declared across the tree.
  import { iconSvgByName } from './icons.js'

  // tier drives the chip color — same blast-radius vocabulary the agents use.
  const TIER_COLOR = { read: 'var(--color-mint)', network: 'var(--color-sky)', write: 'var(--color-peach)', execute: 'var(--color-fuchsia)' }

  let kits = $state([
    { id: 'fmt', name: 'fmt', summary: 'Format & lint source across languages', tier: 'read', enabled: true,
      tools: ['fmt', 'lint', 'check'] },
    { id: 'http', name: 'http', summary: 'Fetch & serve over the network', tier: 'network', enabled: true,
      tools: ['fetch', 'serve', 'curl'] },
    { id: 'sqlite', name: 'sqlite', summary: 'Query & migrate the workspace store', tier: 'write', enabled: true,
      tools: ['query', 'migrate', 'dump'] },
    { id: 'crypto', name: 'crypto', summary: 'Hashing, signing & random', tier: 'read', enabled: false,
      tools: ['hash', 'sign', 'verify', 'rand'] },
    { id: 'git', name: 'git', summary: 'Clone, diff & sync linked subtrees', tier: 'write', enabled: true,
      tools: ['clone', 'diff', 'sync', 'log'] },
    { id: 'shell', name: 'washy', summary: 'A POSIX shell — one wasm module', tier: 'execute', enabled: false,
      tools: ['sh', 'grep', 'sed', 'awk', 'pipe'] },
    { id: 'image', name: 'image', summary: 'Decode, resize & encode images', tier: 'read', enabled: false,
      tools: ['resize', 'encode', 'thumb'] },
    { id: 'pdf', name: 'pdf', summary: 'Render & extract from PDFs', tier: 'read', enabled: false,
      tools: ['render', 'extract', 'merge'] }
  ])

  const enabledCount = $derived(kits.filter((k) => k.enabled).length)
  const toolCount = $derived(kits.filter((k) => k.enabled).reduce((n, k) => n + k.tools.length, 0))
</script>

<div class="h-full bg-paper flex flex-col min-w-0">
  <!-- page header -->
  <div class="flex items-center gap-3 px-6 h-[58px] flex-none border-b border-line">
    <span class="grid place-items-center text-dim [&>svg]:w-[20px] [&>svg]:h-[20px]">{@html iconSvgByName('tools', 20)}</span>
    <div class="flex-1 min-w-0">
      <div class="font-display font-semibold text-[19px] tracking-tight leading-none">Toolkits</div>
      <div class="text-dim text-[12.5px] mt-1">Composable wasm CLI kits available to every sandbox · {enabledCount} enabled · {toolCount} tools</div>
    </div>
  </div>

  <div class="flex-1 overflow-y-auto px-6 py-6">
    <div class="grid gap-3.5 max-w-[920px]" style="grid-template-columns:repeat(auto-fill,minmax(280px,1fr))">
      {#each kits as k}
        <div class="rounded-2xl border border-line bg-card p-4 flex flex-col gap-3 transition"
          style="border-color:{k.enabled ? 'color-mix(in srgb,var(--color-mint) 35%,var(--color-line))' : 'var(--color-line)'}">
          <div class="flex items-start gap-3">
            <span class="w-9 h-9 rounded-xl grid place-items-center flex-none [&>svg]:w-[17px] [&>svg]:h-[17px]"
              style="background:color-mix(in srgb,{TIER_COLOR[k.tier]} 16%,transparent);color:{TIER_COLOR[k.tier]}">{@html iconSvgByName('tools', 17)}</span>
            <div class="flex-1 min-w-0">
              <div class="font-mono font-semibold text-[14px] leading-none">{k.name}</div>
              <div class="text-dim text-[12.5px] mt-1.5 leading-snug">{k.summary}</div>
            </div>
            <!-- enable toggle -->
            <button onclick={() => (k.enabled = !k.enabled)} title={k.enabled ? 'Disable' : 'Enable'}
              class="flex-none w-9 h-5 rounded-full relative transition" style="background:{k.enabled ? 'var(--color-mint)' : 'var(--color-line)'}">
              <span class="absolute top-0.5 w-4 h-4 rounded-full bg-paper transition-all" style="left:{k.enabled ? '18px' : '2px'}"></span>
            </button>
          </div>
          <div class="flex flex-wrap gap-1.5">
            {#each k.tools as t}
              <span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim">{t}</span>
            {/each}
          </div>
          <div class="flex items-center gap-1.5 text-[10px] font-mono uppercase tracking-wider mt-auto"
            style="color:{TIER_COLOR[k.tier]}">
            <span class="w-1.5 h-1.5 rounded-full" style="background:{TIER_COLOR[k.tier]}"></span>{k.tier} tier
          </div>
        </div>
      {/each}
    </div>
  </div>
</div>
