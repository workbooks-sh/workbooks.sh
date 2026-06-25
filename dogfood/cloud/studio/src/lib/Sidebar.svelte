<script>
  import { workspaces, surfacesFor, ui, KIND_ORDER } from './data.svelte.js'
  import { ICO, iconSvg, iconSvgByName, KIND_COLOR } from './icons.js'

  // Each WORKSPACE is a Slack-style collapsible group; its surfaces (channels/apps/agents/workflows)
  // live inside, ordered by kind. No separate workspace switcher — you see all your groups at once.
  let collapsed = $state({})
  let expanded = $state({}) // app row -> show pages

  const kindRank = (k) => KIND_ORDER.indexOf(k)
  const itemsFor = (wsId) => [...surfacesFor(wsId)].sort((a, b) => kindRank(a.kind) - kindRank(b.kind))

  function pick(s) { ui.surfaceId = s.id; ui.workspace = s.workspace; s.unread = 0 }
  const wsUnread = (wsId) => surfacesFor(wsId).reduce((n, s) => n + (s.unread || 0), 0)
</script>

<aside class="w-[264px] h-full bg-paper border-r border-line flex flex-col min-w-0">
  <!-- sidebar header (mirrors .sidehd: 46px, Franie 17px title) -->
  <div class="flex items-center gap-1 px-3.5 h-[46px] flex-none">
    <span class="flex-1 font-display font-semibold text-[17px] tracking-tight">Studio</span>
    <button class="w-[30px] h-[30px] rounded-lg grid place-items-center text-dim hoverwash" title="Search">{@html ICO.search}</button>
    <button class="w-[30px] h-[30px] rounded-lg grid place-items-center text-dim hoverwash" title="New">{@html ICO.plus}</button>
  </div>

  <nav class="flex-1 overflow-y-auto px-1.5 pb-3 pt-1">
    {#each workspaces as w}
      {@const items = itemsFor(w.id)}
      {@const unread = wsUnread(w.id)}
      <div class="mb-0.5">
        <!-- workspace group header — # lead, emoji + name, collapse caret on the far right -->
        <button class="flex items-center gap-2 w-full px-2 py-[7px] rounded-lg hoverwash text-ink font-semibold text-[11.5px]"
          onclick={() => (collapsed[w.id] = !collapsed[w.id])}>
          {#if w.personal}
            <span class="flex-none text-dim grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]" title="Private to you">{@html iconSvgByName('lock', 13)}</span>
          {:else}
            <span class="flex-none text-dim font-mono text-[13px]">#</span>
          {/if}
          <span class="flex-none text-dim grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvg(w.icon)}</span>
          <span class="flex-1 text-left truncate">{w.name}</span>
          {#if unread}<span class="text-dim font-mono text-[10.5px]">{unread}</span>{/if}
          <span class="flex-none text-dim transition-transform duration-150" style="transform:rotate({collapsed[w.id] ? 0 : 90}deg)">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </span>
        </button>

        {#if !collapsed[w.id]}
          <!-- tree guide-bar + indent so the workspace's items read as nested under it -->
          <div class="ml-[15px] pl-2 border-l border-line">
            {#each items as s}
              <div class="group flex items-center gap-2.5 pl-2 pr-2 py-[6px] rounded-lg cursor-pointer text-[13.5px] hoverwash
                  {ui.surfaceId === s.id ? '!bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)]' : ''}"
                onclick={() => pick(s)} role="button" tabindex="0">
                <span class="w-[16px] flex-none grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]"
                  style="color:{KIND_COLOR[s.kind]}">{@html iconSvg(s.icon, s.kind)}</span>
                <span class="flex-1 truncate {s.unread ? 'font-semibold text-ink' : 'text-ink/85'}">{s.name}{#if s.private}<span class="text-dim text-[11px]"> · private</span>{/if}</span>
                {#if s.kind === 'app'}
                  <!-- pages affordance: hover-revealed (or sticky while open), NOT a second caret -->
                  <button title="Open pages"
                    class="flex-none grid place-items-center text-dim hover:text-ink transition-opacity
                      [&>svg]:w-[15px] [&>svg]:h-[15px] {expanded[s.id] ? 'opacity-100 text-ink' : 'opacity-0 group-hover:opacity-100'}"
                    onclick={(e) => { e.stopPropagation(); expanded[s.id] = !expanded[s.id] }}>{@html ICO.tree}</button>
                {/if}
                {#if s.unread}
                  <span class="min-w-[18px] h-[18px] px-1.5 rounded-full grid place-items-center text-[11px] font-bold font-mono"
                    style="background:var(--color-blue);color:#10120f">{s.unread}</span>
                {/if}
              </div>
              {#if s.kind === 'app' && expanded[s.id]}
                <div class="ml-[19px] pl-2 border-l border-line">
                  {#each s.payload.pages as p}
                    <div class="px-2 py-[3px] rounded-md text-[12.5px] text-dim hoverwash cursor-pointer">{p.label}<span class="opacity-50"> · {p.path}</span></div>
                  {/each}
                </div>
              {/if}
            {/each}
          </div>
        {/if}
      </div>
    {/each}
  </nav>
</aside>
