<script>
  // First-run for a chat-native agent runtime. The aha is concrete: an agent posts the output of real
  // code it just ran into a channel. So we get there fast — name + import a repo → meet the agent →
  // watch it run real code → set its blast radius → invite the team. No pricing/seat math (seatless).
  import { auth, finishOnboarding } from './auth.svelte.js'
  import { iconSvgByName } from './icons.js'

  let step = $state(0)
  const STEPS = ['Workspace', 'Your agent', 'Blast radius', 'Team']

  // step 0 — name + seed the workspace
  let nexusName = $state('')
  let source = $state(null) // 'github' | 'local' | 'sample'
  let repo = $state('')

  // step 1 — the scripted first run
  let running = $state(false)
  let ran = $state(false)
  const RUN_STEPS = ['reading repo', 'running tests', 'summarizing failures']
  let runProgress = $state(-1)
  function runAgent() {
    running = true; runProgress = 0
    const tick = () => {
      if (runProgress < RUN_STEPS.length - 1) { runProgress++; setTimeout(tick, 700) }
      else { running = false; ran = true }
    }
    setTimeout(tick, 600)
  }

  // step 2 — least-privilege: what the agent may touch (the differentiator, taught at first run)
  let caps = $state([
    { id: 'repo-read', label: 'Read repo files', on: true, tier: 'read' },
    { id: 'tests-run', label: 'Run tests', on: true, tier: 'execute' },
    { id: 'net', label: 'Reach the network', on: false, tier: 'network' },
    { id: 'db-write', label: 'Write to databases', on: false, tier: 'write' }
  ])

  // step 3 — seatless team invite
  let invites = $state('')

  const canNext = $derived(
    step === 0 ? (!!nexusName.trim() && !!source) :
    step === 1 ? ran :
    true
  )
  function next() { if (step < STEPS.length - 1) step++; else finishOnboarding() }
  function back() { if (step > 0) step-- }
</script>

<div class="min-h-screen bg-paper flex flex-col">
  <!-- progress rail -->
  <div class="h-1 flex-none flex">
    {#each STEPS as _, i}
      <div class="flex-1 transition-colors" style="background:{i <= step ? 'var(--color-sky)' : 'var(--color-line)'}"></div>
    {/each}
  </div>

  <div class="flex-1 grid place-items-center px-6 py-10 overflow-y-auto">
    <div class="w-[min(560px,94vw)]">
      <div class="text-[11px] font-mono uppercase tracking-[0.2em] text-dim mb-2">Step {step + 1} / {STEPS.length} · {STEPS[step]}</div>

      {#if step === 0}
        <h1 class="font-display font-bold text-[26px] mb-1">Set up your runtime</h1>
        <p class="text-dim text-[14px] mb-6">Name it, then bring your code in — it becomes a workspace, a subtree of your monorepo.</p>
        <input bind:value={nexusName} placeholder="Nexus name — e.g. acme"
          class="w-full bg-card border border-line rounded-xl px-3.5 py-3 text-[15px] mb-4 focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
        <div class="grid grid-cols-3 gap-2.5">
          {#each [['github','🐙','Connect GitHub'],['local','📁','Local folder'],['sample','✨','Use a sample']] as [id, glyph, label]}
            <button onclick={() => (source = id)}
              class="rounded-xl border p-3.5 text-left transition" style="border-color:{source === id ? 'color-mix(in srgb,var(--color-sky) 60%,var(--color-line))' : 'var(--color-line)'};background:{source === id ? 'color-mix(in srgb,var(--color-sky) 10%,transparent)' : 'transparent'}">
              <div class="text-[20px] mb-1">{glyph}</div><div class="text-[13px]">{label}</div>
            </button>
          {/each}
        </div>
        {#if source === 'github'}
          <input bind:value={repo} placeholder="owner/repo" class="mt-3 w-full bg-card border border-line rounded-xl px-3.5 py-2.5 text-[14px] focus:outline-none" />
        {/if}

      {:else if step === 1}
        <h1 class="font-display font-bold text-[26px] mb-1">Meet your agent</h1>
        <p class="text-dim text-[14px] mb-6"><b>Workhorse</b> lives in your channel. Ask it something — it runs <i>real code</i> in the sandbox and replies. Try it:</p>
        <div class="rounded-2xl border border-line bg-card overflow-hidden">
          <div class="px-4 py-2.5 border-b border-line text-[12px] font-mono text-dim flex items-center gap-2">{@html iconSvgByName('chat-bubble', 13)} #general</div>
          <div class="p-4 flex flex-col gap-3">
            <div class="text-[14px]"><span class="font-semibold">you</span> <span class="text-ink/85">@Workhorse run the tests and summarize failures</span></div>
            {#if running || ran}
              <div class="rounded-xl border border-line p-3 flex flex-col gap-1.5">
                {#each RUN_STEPS as rs, i}
                  <div class="flex items-center gap-2.5 text-[13px]">
                    <span class="w-2.5 h-2.5 rounded-full flex-none" style="background:{i <= runProgress ? 'var(--color-mint)' : 'var(--color-line)'}"></span>
                    <span class={i <= runProgress ? 'text-ink' : 'text-dim'}>{rs}</span>
                    {#if i < runProgress || ran}<span class="ml-auto" style="color:var(--color-mint)">✓</span>{/if}
                  </div>
                {/each}
              </div>
            {/if}
            {#if ran}
              <div class="text-[14px]"><span class="font-semibold" style="color:var(--color-mint)">Workhorse</span> <span class="text-ink/85">Ran 42 tests — 2 failures in <code>auth_test</code>. Both are an expired fixture token. Want me to open an issue?</span></div>
            {/if}
          </div>
          {#if !ran}
            <div class="p-3 border-t border-line">
              <button onclick={runAgent} disabled={running} class="w-full rounded-xl bg-ink text-paper py-2.5 text-[14px] font-medium hover:opacity-90 disabled:opacity-50">
                {running ? 'Running real code…' : '▶ Send & run'}
              </button>
            </div>
          {/if}
        </div>

      {:else if step === 2}
        <h1 class="font-display font-bold text-[26px] mb-1">Set its blast radius</h1>
        <p class="text-dim text-[14px] mb-2">The same gate that bounds your code bounds the agent. You can prove its maximum reach <i>before</i> it runs — and no chat platform can.</p>
        <div class="rounded-xl px-3.5 py-2.5 mb-5 text-[13px]" style="background:color-mix(in srgb,var(--color-sky) 10%,transparent)">
          <b>Workhorse can, at most:</b> {caps.filter((c) => c.on).map((c) => c.label.toLowerCase()).join(', ') || 'read what you pass it'}.
        </div>
        <div class="flex flex-col gap-2">
          {#each caps as c}
            <button onclick={() => (c.on = !c.on)} class="flex items-center gap-3 rounded-xl border border-line px-3.5 py-3 text-left">
              <span class="w-9 h-5 rounded-full flex-none relative transition" style="background:{c.on ? 'var(--color-mint)' : 'var(--color-line)'}">
                <span class="absolute top-0.5 w-4 h-4 rounded-full bg-paper transition-all" style="left:{c.on ? '18px' : '2px'}"></span>
              </span>
              <span class="text-[14px]">{c.label}</span>
              <span class="ml-auto text-[10px] font-mono uppercase text-dim">{c.tier}</span>
            </button>
          {/each}
        </div>

      {:else}
        <h1 class="font-display font-bold text-[26px] mb-1">Invite your team</h1>
        <p class="text-dim text-[14px] mb-6">Seatless — invite anyone, there’s no per-seat cost. You pay for committed compute, not headcount.</p>
        <textarea bind:value={invites} rows="3" placeholder="emails, comma or newline separated"
          class="w-full bg-card border border-line rounded-xl px-3.5 py-3 text-[14px] focus:outline-none resize-none"></textarea>
      {/if}

      <div class="flex items-center gap-2 mt-7">
        {#if step > 0}<button onclick={back} class="px-4 py-2.5 text-[14px] text-dim hover:text-ink">Back</button>{/if}
        <span class="flex-1"></span>
        {#if step === STEPS.length - 1}
          <button onclick={finishOnboarding} class="px-4 py-2.5 text-[14px] text-dim hover:text-ink">Skip</button>
        {/if}
        <button onclick={next} disabled={!canNext}
          class="px-5 py-2.5 rounded-xl bg-ink text-paper text-[14px] font-medium hover:opacity-90 disabled:opacity-40 transition">
          {step === STEPS.length - 1 ? 'Enter Workbooks →' : 'Continue'}
        </button>
      </div>
    </div>
  </div>
</div>
