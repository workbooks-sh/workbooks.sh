<script>
  // DEFAULT view of a workflow surface — a FEED OF OUTPUTS, newest first. A non-technical user opening
  // "daily digest" sees the digests themselves, not run metadata. Status + step logs are demoted to a
  // subtle secondary twirl. Clicking an output opens it in an inline right panel that pushes the feed over.
  import { surfaceById, runsFor, startRun, isInvocable } from './data.svelte.js'
  import { iconSvgByName, KIND_COLOR } from './icons.js'
  import RunDialog from './RunDialog.svelte'
  import OutputView from './OutputView.svelte'

  let { surfaceId, onEdit } = $props()
  const s = $derived(surfaceById(surfaceId))
  const runs = $derived(runsFor(surfaceId))
  const invocable = $derived(isInvocable(s))
  let dialog = $state(null)         // null | 'run' | 'test'
  let menuOpen = $state(false)
  let logsFor = $state(null)        // run id whose step log footer is expanded
  let active = $state({})           // run id -> active output tab index
  let sel = $state(null)            // { runId, idx } — output open in the right panel
  let showHistory = $state(false)   // history is lazy-loaded on demand
  const actIdx = (r) => active[r.id] ?? 0

  // group the feed by recency; History is held back until the user loads it
  const BUCKETS = [
    { key: 'today', label: 'Today' }, { key: 'yesterday', label: 'Yesterday' },
    { key: 'week', label: 'This week' }, { key: 'history', label: 'History' }
  ]
  const groups = $derived(BUCKETS
    .map((b) => ({ ...b, items: runs.filter((r) => (r.bucket || 'history') === b.key) }))
    .filter((g) => g.items.length))
  const historyCount = $derived(runs.filter((r) => (r.bucket || 'history') === 'history').length)

  function doRun(values, test) { startRun(surfaceId, values); }
  const selRun = $derived(sel && runs.find((r) => r.id === sel.runId))
  const selOutput = $derived(selRun && selRun.outputs[sel.idx])

  const STATUS = {
    success: { c: 'var(--color-mint)', icon: 'check-circle', label: 'Success' },
    blocked: { c: 'var(--color-peach)', icon: 'prohibition', label: 'Blocked' },
    failed:  { c: 'var(--color-peach)', icon: 'warning-circle', label: 'Failed' },
    running: { c: 'var(--color-blue)', icon: 'refresh-double', label: 'Running' },
    queued:  { c: 'var(--color-dim)', icon: 'clock', label: 'Queued' }
  }
  const st = (k) => STATUS[k] || STATUS.queued
  const OK = {
    doc:  { icon: 'page', c: 'var(--color-sky)', label: 'Document' },
    chat: { icon: 'chat-bubble', c: 'var(--color-blue)', label: 'Chat' },
    data: { icon: 'database', c: 'var(--color-mint)', label: 'Data' },
    app:  { icon: 'app-window', c: 'var(--color-peach)', label: 'App' }
  }
  const ok = (k) => OK[k] || OK.doc

  // a couple of readable lines for the feed preview (no technical chrome)
  function lines(o) {
    if (o.kind === 'doc') return o.body.filter((b) => b.p || b.li).slice(0, 3).map((b) => b.p || `• ${b.li}`)
    if (o.kind === 'chat') return o.messages.slice(0, 2).map((m) => m.text)
    if (o.kind === 'data') return [`${o.rows.length} ${o.cols[0].toLowerCase()}s · all ${o.rows[0][1]}`]
    return [o.preview || '']
  }
</script>

{#if s}
  <section class="flex flex-col min-w-0 h-full bg-paper">
    <header class="flex items-center gap-2.5 px-4 h-[57px] border-b border-line flex-none">
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR.workflow}">{@html iconSvgByName(s.icon, 18)}</span>
      <div class="min-w-0">
        <div class="font-display font-semibold leading-tight">{s.name}</div>
        <div class="text-dim text-[12.5px] truncate">{s.purpose || 'Workflow'} · {runs.length} runs</div>
      </div>
      <span class="flex-1"></span>
      <!-- trigger context: explains how this flow starts (and why Run may be absent) -->
      <span class="hidden md:flex items-center gap-1.5 text-dim text-[12px] mr-1 [&>svg]:w-[13px] [&>svg]:h-[13px]">
        {@html iconSvgByName(invocable ? 'play' : 'calendar', 13)}{s.payload?.triggerLabel || (invocable ? 'Manual' : 'Automatic')}
      </span>

      {#if invocable}
        <!-- split button: Run (real invocation) + caret → more actions -->
        <div class="relative flex">
          <button onclick={() => (dialog = 'run')} class="flex items-center gap-1.5 text-[13px] pl-3 pr-2.5 py-1.5 rounded-l-lg text-ink [&>svg]:w-[15px] [&>svg]:h-[15px]"
            style="background:color-mix(in srgb,var(--color-mint) 24%,transparent)">{@html iconSvgByName('play', 15)} Run</button>
          <button onclick={(e) => { e.stopPropagation(); menuOpen = !menuOpen }} aria-label="More run options"
            class="grid place-items-center px-1.5 rounded-r-lg border-l [&>svg]:w-[14px] [&>svg]:h-[14px]"
            style="background:color-mix(in srgb,var(--color-mint) 24%,transparent); border-color:color-mix(in srgb,var(--color-ink) 14%,transparent)">{@html iconSvgByName('nav-arrow-down', 14)}</button>
          {#if menuOpen}
            <div class="absolute right-0 top-full mt-1.5 z-30 min-w-[170px] rounded-xl border border-line bg-card py-1.5" style="box-shadow:0 16px 36px rgba(0,0,0,.4)">
              <button onclick={() => { dialog = 'test'; menuOpen = false }} class="flex items-center gap-2.5 w-full text-left px-3 py-2 text-[13px] hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('flash', 14)} Test run</button>
            </div>
          {/if}
        </div>
      {:else}
        <!-- not invocable (scheduled / reactive): no "Run now", but you can still test it -->
        <button onclick={() => (dialog = 'test')} class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('flash', 14)} Test run</button>
      {/if}

      <button onclick={onEdit} title="Edit flow"
        class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('edit-pencil', 15)} Edit flow</button>
    </header>

    <!-- split: feed (left) + inline output panel (right) -->
    <div class="flex-1 min-h-0 flex">
      <div class="flex-1 overflow-y-auto min-w-0" style="background:var(--color-well)">
        <div class="{sel ? 'px-5' : 'max-w-2xl mx-auto px-5'} py-6 flex flex-col gap-6">
          {#each groups as g (g.key)}
            {#if g.key !== 'history' || showHistory}
              <div class="flex flex-col gap-4">
                <!-- group divider: label on the left, rule to the right edge -->
                <div class="flex items-center gap-3 pt-1">
                  <span class="text-[11px] font-mono uppercase tracking-wider text-dim flex-none">{g.label}</span>
                  <span class="flex-1 h-px" style="background:var(--color-line)"></span>
                </div>

                {#each g.items as r (r.id)}
                  {@const S = st(r.status)}
            {@const i = actIdx(r)}
            {@const o = r.outputs[i]}
            {@const K = o && ok(o.kind)}
            <!-- ONE card per run: status + output tabs in the header, the active output as the body,
                 and the logs as an expanding footer — so it reads as a single thing -->
            <div class="rounded-xl border bg-paper overflow-hidden transition-colors
              {sel?.runId === r.id ? 'border-[color-mix(in_srgb,var(--color-sky)_50%,var(--color-line))]' : 'border-line'}">

              <!-- header: output tabs (left) · pass/fail mark + time (right) -->
              <div class="flex items-center gap-2 px-3 pt-2.5 pb-2">
                {#if r.outputs.length}
                  <div class="flex items-center gap-1 min-w-0">
                    {#each r.outputs as ot, ti}
                      {@const TK = ok(ot.kind)}
                      <button onclick={() => (active[r.id] = ti)}
                        class="flex items-center gap-1.5 text-[12px] px-2 py-1 rounded-lg whitespace-nowrap [&>svg]:w-[13px] [&>svg]:h-[13px]
                          {ti === i ? 'text-ink' : 'text-dim hoverwash'}" style={ti === i ? `background:color-mix(in srgb,${TK.c} 13%,transparent)` : ''}>
                        <span style="color:{TK.c}">{@html iconSvgByName(TK.icon, 13)}</span>{TK.label}
                      </button>
                    {/each}
                  </div>
                {:else}
                  <span class="text-dim text-[12px] px-1">Running…</span>
                {/if}
                <span class="flex-1"></span>
                <span class="grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px] {r.status === 'running' ? 'animate-spin' : ''}" style="color:{S.c}" title={S.label}>{@html iconSvgByName(S.icon, 15)}</span>
                <span class="text-dim text-[12px]">{r.when}</span>
              </div>

              <!-- body: the active output (click → full view in the right panel) -->
              {#if o}
                <button onclick={() => (sel = { runId: r.id, idx: i })} class="text-left w-full px-4 pb-3.5 pt-0.5 hover:bg-[color-mix(in_srgb,var(--color-ink)_3%,transparent)]">
                  <h3 class="font-display font-semibold text-[15px] leading-tight mb-1">{o.title}</h3>
                  <div class="flex flex-col gap-0.5">
                    {#each lines(o) as ln}<p class="text-[13px] text-ink/70 leading-snug line-clamp-1">{ln}</p>{/each}
                  </div>
                </button>
              {:else}
                <div class="px-4 pb-3.5 text-dim text-[13px]">Running {s.name}…</div>
              {/if}

              <!-- footer: logs expander, part of the same card -->
              <button onclick={() => (logsFor = logsFor === r.id ? null : r.id)}
                class="flex items-center gap-1.5 w-full px-4 py-2 border-t border-line text-[11.5px] text-dim hover:text-ink hoverwash [&>svg]:w-[12px] [&>svg]:h-[12px]">
                <span class="transition-transform" style="transform:rotate({logsFor === r.id ? 90 : 0}deg)">{@html iconSvgByName('nav-arrow-right', 12)}</span>
                Logs <span class="text-dim/70">· {r.steps.length} steps · {r.duration} · {r.id}</span>
              </button>
              {#if logsFor === r.id}
                <div class="px-4 py-3 border-t border-line flex flex-col gap-2" style="background:var(--color-well)">
                  {#each r.steps as step, si}
                    {@const SS = st(step.status)}
                    <div class="flex items-start gap-2">
                      <span class="grid place-items-center w-4 h-4 mt-[1px] flex-none [&>svg]:w-[13px] [&>svg]:h-[13px]" style="color:{SS.c}">{@html iconSvgByName(SS.icon, 13)}</span>
                      <div class="min-w-0">
                        <span class="text-[12.5px] font-medium">{step.name}</span>
                        {#if step.branch}<span class="ml-1.5 text-[10px] font-mono uppercase px-1.5 py-0.5 rounded" style="color:{step.branch === 'true' ? 'var(--color-mint)' : 'var(--color-peach)'};background:color-mix(in srgb,{step.branch === 'true' ? 'var(--color-mint)' : 'var(--color-peach)'} 14%,transparent)">{step.branch}</span>{/if}
                        <div class="text-dim text-[12px]">{step.detail}</div>
                      </div>
                    </div>
                  {/each}
                </div>
              {/if}
                </div>
                {/each}
              </div>
            {/if}
          {/each}

          <!-- History is lazy: load it only when asked -->
          {#if historyCount && !showHistory}
            <div class="flex flex-col gap-4">
              <div class="flex items-center gap-3 pt-1">
                <span class="text-[11px] font-mono uppercase tracking-wider text-dim flex-none">History</span>
                <span class="flex-1 h-px" style="background:var(--color-line)"></span>
              </div>
              <button onclick={() => (showHistory = true)}
                class="self-center flex items-center gap-1.5 text-[12.5px] text-dim hover:text-ink px-3.5 py-2 rounded-lg border border-line hoverwash [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('clock', 13)} Load {historyCount} earlier run{historyCount > 1 ? 's' : ''}</button>
            </div>
          {/if}

          {#if !runs.length}
            <div class="text-center text-dim text-[13.5px] py-16">No runs yet. Hit <b class="text-ink">Run</b> to start one.</div>
          {/if}
        </div>
      </div>

      <!-- inline output panel -->
      {#if selOutput}
        <aside class="w-[460px] flex-none border-l border-line bg-paper flex flex-col min-h-0">
          <div class="flex items-center gap-2.5 px-4 h-[52px] border-b border-line flex-none">
            <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]" style="color:{ok(selOutput.kind).c}">{@html iconSvgByName(ok(selOutput.kind).icon, 16)}</span>
            <div class="min-w-0 flex-1">
              <div class="font-display font-semibold text-[14px] leading-tight truncate">{selOutput.title}</div>
              <div class="text-dim text-[11.5px]">{selRun.id} · {selRun.when}</div>
            </div>
            <button onclick={() => (sel = null)} class="grid place-items-center w-8 h-8 rounded-lg text-dim hover:text-ink hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('xmark', 15)}</button>
          </div>
          <!-- tabs when a run produced multiple outputs -->
          {#if selRun.outputs.length > 1}
            <div class="flex items-center gap-1 px-3 py-2 border-b border-line flex-none overflow-x-auto">
              {#each selRun.outputs as o, i}
                <button onclick={() => (sel = { runId: selRun.id, idx: i })}
                  class="flex items-center gap-1.5 text-[12px] px-2.5 py-1.5 rounded-lg whitespace-nowrap [&>svg]:w-[13px] [&>svg]:h-[13px]
                    {sel.idx === i ? 'text-ink' : 'text-dim hoverwash'}" style={sel.idx === i ? `background:color-mix(in srgb,${ok(o.kind).c} 14%,transparent)` : ''}>
                  <span style="color:{ok(o.kind).c}">{@html iconSvgByName(ok(o.kind).icon, 13)}</span>{o.title}
                </button>
              {/each}
            </div>
          {/if}
          <div class="flex-1 overflow-y-auto min-h-0">
            <OutputView output={selOutput} />
          </div>
        </aside>
      {/if}
    </div>
  </section>

  {#if dialog}<RunDialog surface={s} test={dialog === 'test'} onRun={(v) => doRun(v, dialog === 'test')} onClose={() => (dialog = null)} />{/if}
{/if}

<svelte:window onclick={() => (menuOpen = false)} />
