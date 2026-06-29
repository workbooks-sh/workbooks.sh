<script>
  // Skill-KB — the inverted skill registry as the primary surface. Instead of hunting hundreds of
  // skills, describe what you need: the KB recalls the matching capability + source skills, and can
  // author a fresh, targeted .work skill on demand. Backend: /cloud/skills/{stats,recall,author}.
  import { api } from './api.js'
  import { ICO, iconSvgByName } from './icons.js'

  let query = $state('')
  let stats = $state(null)
  let result = $state(null) // recall result
  let authored = $state(null) // authored skill
  let loading = $state(false)
  let authoring = $state(false)
  let error = $state('')

  const examples = [
    'rebase my branch without losing commits',
    'safely undo a commit I already pushed',
    'split unrelated edits into two commits',
    'find which commit introduced a bug',
  ]

  $effect(() => { loadStats() })

  async function loadStats() {
    try { stats = await api.rt('/cloud/skills/stats') } catch (e) { /* unbuilt until first recall */ }
  }

  async function recall(q) {
    const text = (q ?? query).trim()
    if (!text) return
    query = text
    loading = true; error = ''; authored = null; result = null
    try {
      result = await api.cloudPost('/cloud/skills/recall', { query: text })
      if (!stats?.built) loadStats()
    } catch (e) { error = e.message || 'recall failed' } finally { loading = false }
  }

  async function author() {
    if (!query.trim()) return
    authoring = true; error = ''
    try {
      authored = await api.cloudPost('/cloud/skills/author', { query: query.trim() })
    } catch (e) { error = e.message || 'author failed' } finally { authoring = false }
  }

  function onKey(e) { if (e.key === 'Enter') recall() }
  const pct = (s) => Math.round(Math.max(0, Math.min(1, s)) * 100)
</script>

<div class="h-full overflow-y-auto" style="background:var(--color-paper)">
  <div class="max-w-[860px] mx-auto px-6 py-10">

    <!-- Hero -->
    <div class="flex items-center gap-3 mb-1">
      <span class="grid place-items-center w-9 h-9 rounded-xl" style="background:color-mix(in srgb,var(--color-sky) 22%,transparent);color:var(--color-ink)">{@html ICO.skillkb}</span>
      <h1 class="text-[22px] font-semibold" style="font-family:var(--font-display);color:var(--color-ink)">Skills</h1>
    </div>
    <p class="text-[13.5px] leading-relaxed mb-5" style="color:var(--color-dim)">
      Don't hunt through hundreds of skills. Describe what you need — the knowledge base recalls the
      matching <em>capability</em> and its source skills, and can <strong>author a fresh, targeted skill</strong>
      grounded in them.
    </p>

    <!-- Search -->
    <label class="flex items-center gap-2 px-3.5 h-12 rounded-2xl border bg-card mb-3"
      style="border-color:var(--color-line);background:var(--color-card)">
      <span style="color:var(--color-dim)">{@html iconSvgByName('search', 18)}</span>
      <input bind:value={query} onkeydown={onKey} placeholder="Describe the task you want a skill for…"
        class="flex-1 bg-transparent border-0 outline-none text-[14px]" style="color:var(--color-ink)" />
      <button onclick={() => recall()} disabled={loading || !query.trim()}
        class="px-3.5 h-8 rounded-xl text-[12.5px] font-semibold disabled:opacity-40"
        style="background:var(--color-ink);color:var(--color-paper)">{loading ? 'Recalling…' : 'Recall'}</button>
    </label>

    <!-- example chips + stats -->
    <div class="flex items-center justify-between flex-wrap gap-2 mb-7">
      <div class="flex gap-1.5 flex-wrap">
        {#each examples as ex}
          <button onclick={() => recall(ex)} class="px-2.5 py-1 rounded-lg text-[11.5px] border transition hover:opacity-80"
            style="border-color:var(--color-line);color:var(--color-dim);background:var(--color-card)">{ex}</button>
        {/each}
      </div>
      {#if stats}
        <div class="text-[11px] font-mono" style="color:var(--color-dim)">
          {stats.skills} skills · {stats.capabilities} capabilities · {stats.chunks} chunks
        </div>
      {/if}
    </div>

    {#if error}
      <div class="px-3.5 py-2.5 rounded-xl text-[12.5px] mb-5" style="background:color-mix(in srgb,var(--color-peach) 30%,transparent);color:var(--color-ink)">{error}</div>
    {/if}

    {#if loading}
      <div class="text-[13px] py-10 text-center" style="color:var(--color-dim)">Recalling from the knowledge base…</div>
    {/if}

    {#if result}
      <!-- Capability (the obfuscation layer) -->
      {#if result.capability}
        <div class="rounded-2xl border p-4 mb-5" style="border-color:var(--color-line);background:var(--color-card)">
          <div class="flex items-center gap-2 mb-1.5">
            <span class="text-[10px] font-mono uppercase px-1.5 py-0.5 rounded-md" style="color:var(--color-sky);background:color-mix(in srgb,var(--color-sky) 16%,transparent)">capability</span>
            <span class="text-[10px]" style="color:var(--color-dim)">{result.capability.skill_count} related skills</span>
          </div>
          <div class="text-[15px] font-semibold mb-1" style="color:var(--color-ink)">{result.capability.name}</div>
          <div class="text-[13px] leading-relaxed" style="color:var(--color-dim)">{result.capability.summary}</div>
        </div>
      {/if}

      <!-- Author CTA -->
      <button onclick={author} disabled={authoring}
        class="w-full flex items-center justify-center gap-2 h-11 rounded-2xl text-[13.5px] font-semibold mb-6 disabled:opacity-50 transition"
        style="background:color-mix(in srgb,var(--color-mint) 40%,transparent);color:var(--color-ink);border:1px solid var(--color-line)">
        <span>{@html iconSvgByName('magic-wand', 17)}</span>
        {authoring ? 'Authoring a targeted skill…' : 'Author a skill for this'}
      </button>

      <!-- Authored skill -->
      {#if authored}
        <div class="rounded-2xl border mb-7 overflow-hidden" style="border-color:var(--color-line)">
          <div class="flex items-center justify-between px-3.5 py-2 border-b" style="border-color:var(--color-line);background:var(--color-card)">
            <span class="text-[11px] font-mono uppercase" style="color:var(--color-dim)">authored · grounded in {authored.sources?.length || 0} skills · {authored.license}</span>
            <button onclick={() => navigator.clipboard?.writeText(authored.skill)} class="text-[11px] px-2 py-0.5 rounded-md border" style="border-color:var(--color-line);color:var(--color-dim)">Copy</button>
          </div>
          <pre class="px-4 py-3 text-[11.5px] leading-relaxed overflow-x-auto m-0 whitespace-pre-wrap" style="font-family:var(--font-mono);color:var(--color-ink);background:var(--color-paper)">{authored.skill}</pre>
        </div>
      {/if}

      <!-- Source skills (drill-down) -->
      {#if result.sources?.length}
        <div class="text-[11px] font-mono uppercase mb-2" style="color:var(--color-dim)">source skills — drill down</div>
        <div class="grid gap-2.5 mb-7" style="grid-template-columns:repeat(auto-fill,minmax(250px,1fr))">
          {#each result.sources as s}
            <div class="rounded-xl border p-3" style="border-color:var(--color-line);background:var(--color-card)">
              <div class="text-[13px] font-semibold mb-1 leading-snug" style="color:var(--color-ink)">{s.title}</div>
              {#if s.description}<div class="text-[11.5px] leading-snug mb-2 line-clamp-2" style="color:var(--color-dim)">{s.description}</div>{/if}
              <div class="flex gap-1.5">
                {#if s.network}<span class="text-[9.5px] font-mono uppercase px-1.5 py-0.5 rounded" style="color:var(--color-sky);background:color-mix(in srgb,var(--color-sky) 14%,transparent)">network</span>{/if}
                {#if s.destructive}<span class="text-[9.5px] font-mono uppercase px-1.5 py-0.5 rounded" style="color:var(--color-peach);background:color-mix(in srgb,var(--color-peach) 18%,transparent)">destructive</span>{/if}
              </div>
            </div>
          {/each}
        </div>
      {/if}

      <!-- Ranked chunk hits -->
      {#if result.hits?.length}
        <div class="text-[11px] font-mono uppercase mb-2" style="color:var(--color-dim)">recalled passages</div>
        <div class="flex flex-col gap-2">
          {#each result.hits as h}
            <div class="rounded-xl border p-3" style="border-color:var(--color-line);background:var(--color-card)">
              <div class="flex items-center gap-2 mb-1">
                <div class="flex-1 h-1 rounded-full overflow-hidden" style="background:var(--color-line)">
                  <div class="h-full rounded-full" style="width:{pct(h.score)}%;background:var(--color-mint)"></div>
                </div>
                <span class="text-[10px] font-mono" style="color:var(--color-dim)">{pct(h.score)}%</span>
              </div>
              <div class="text-[12px] font-semibold" style="color:var(--color-ink)">{h.skill} · {h.anchor}</div>
              <div class="text-[11.5px] leading-snug mt-0.5" style="color:var(--color-dim)">{h.text}</div>
            </div>
          {/each}
        </div>
      {/if}
    {/if}

    {#if !loading && !result}
      <div class="text-center py-12">
        <div class="text-[13px]" style="color:var(--color-dim)">Type a task above, or try an example, to see the KB recall a capability and its skills.</div>
      </div>
    {/if}
  </div>
</div>
