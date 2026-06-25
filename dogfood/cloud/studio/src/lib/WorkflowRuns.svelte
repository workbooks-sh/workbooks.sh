<script>
  // DEFAULT view of a workflow surface — a FEED OF OUTPUTS, newest first. A non-technical user opening
  // "daily digest" sees the digests themselves, not run metadata. Status + step logs are demoted to a
  // subtle secondary twirl. Clicking an output opens it in an inline right panel that pushes the feed over.
  import { surfaceById, runsFor, startRun } from './data.svelte.js'
  import { iconSvgByName, KIND_COLOR } from './icons.js'
  import RunDialog from './RunDialog.svelte'
  import OutputView from './OutputView.svelte'

  let { surfaceId, onEdit } = $props()
  const s = $derived(surfaceById(surfaceId))
  const runs = $derived(runsFor(surfaceId))
  let runOpen = $state(false)
  let logsFor = $state(null)        // run id whose step log is twirled open
  let sel = $state(null)            // { runId, idx } — output open in the right panel

  function doRun(values) { startRun(surfaceId, values) }
  const selRun = $derived(sel && runs.find((r) => r.id === sel.runId))
  const selOutput = $derived(selRun && selRun.outputs[sel.idx])

  const STATUS = {
    success: { c: 'var(--color-mint)', icon: 'check-circle', label: 'Success' },
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
      <button onclick={() => (runOpen = true)} class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg text-ink [&>svg]:w-[15px] [&>svg]:h-[15px]"
        style="background:color-mix(in srgb,var(--color-mint) 22%,transparent)">{@html iconSvgByName('play', 15)} Run now</button>
      <button onclick={onEdit} title="Edit flow"
        class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('edit-pencil', 15)} Edit flow</button>
    </header>

    <!-- split: feed (left) + inline output panel (right) -->
    <div class="flex-1 min-h-0 flex">
      <div class="flex-1 overflow-y-auto min-w-0" style="background:var(--color-well)">
        <div class="{sel ? 'px-5' : 'max-w-2xl mx-auto px-5'} py-5 flex flex-col gap-3">
          {#each runs as r (r.id)}
            {@const S = st(r.status)}
            <div class="flex flex-col gap-1.5">
              <!-- one card per OUTPUT — the artifact itself leads -->
              {#each r.outputs as o, i}
                {@const K = ok(o.kind)}
                <button onclick={() => (sel = { runId: r.id, idx: i })}
                  class="text-left rounded-xl border bg-paper px-4 py-3.5 transition-colors
                    {sel?.runId === r.id && sel?.idx === i ? 'border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]' : 'border-line hover:border-[color-mix(in_srgb,var(--color-ink)_18%,var(--color-line))]'}">
                  <div class="flex items-center gap-2 mb-1.5 text-[11.5px]">
                    <span class="grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]" style="color:{K.c}">{@html iconSvgByName(K.icon, 13)}</span>
                    <span class="text-dim">{K.label}</span>
                    <span class="flex-1"></span>
                    <span class="w-1.5 h-1.5 rounded-full" style="background:{S.c}"></span>
                    <span class="text-dim">{r.when}</span>
                  </div>
                  <h3 class="font-display font-semibold text-[15px] leading-tight mb-1">{o.title}</h3>
                  <div class="flex flex-col gap-0.5">
                    {#each lines(o) as ln}<p class="text-[13px] text-ink/70 leading-snug line-clamp-1">{ln}</p>{/each}
                  </div>
                </button>
              {/each}

              {#if !r.outputs.length}
                <div class="rounded-xl border border-line bg-paper px-4 py-3.5 flex items-center gap-2.5 text-[13px] text-dim">
                  <span class="grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px] animate-spin" style="color:{S.c}">{@html iconSvgByName('refresh-double', 15)}</span>
                  Running {s.name}…
                </div>
              {/if}

              <!-- subtle, secondary: status + step log twirl (for whoever wants the technical detail) -->
              <button onclick={() => (logsFor = logsFor === r.id ? null : r.id)}
                class="self-start flex items-center gap-1.5 pl-1 text-[11.5px] text-dim/70 hover:text-dim [&>svg]:w-[12px] [&>svg]:h-[12px]">
                <span class="transition-transform" style="transform:rotate({logsFor === r.id ? 90 : 0}deg)">{@html iconSvgByName('nav-arrow-right', 12)}</span>
                <span style="color:{S.c}">{S.label}</span>
                <span>· {r.steps.length} steps · {r.duration} · {r.id}</span>
              </button>
              {#if logsFor === r.id}
                <div class="ml-3 pl-3 border-l border-line flex flex-col gap-1.5 py-1">
                  {#each r.steps as step, i}
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

          {#if !runs.length}
            <div class="text-center text-dim text-[13.5px] py-16">No runs yet. Hit <b class="text-ink">Run now</b> to start one.</div>
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

  {#if runOpen}<RunDialog surface={s} onRun={doRun} onClose={() => (runOpen = false)} />{/if}
{/if}
