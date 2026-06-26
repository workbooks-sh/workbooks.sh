<script>
  // You — the personal home, at parity with the legacy "You" surface: editable profile, a GitHub-style
  // contribution heatmap (with cryptographically-verified metering overlay), contributions, usage, CLI
  // tokens, author device keys, and preferences. Live against /cloud/profile · /cloud/keys ·
  // /api/platform/tokens; in demo mode (auth.offline) it renders believable fixtures. The sub-nav
  // (YouNav) drives ui.youSection; we scroll the matching anchor into view.
  import { ui, setTheme } from './data.svelte.js'
  import { auth, logout } from './auth.svelte.js'
  import { iconSvgByName } from './icons.js'
  import CredRow from './CredRow.svelte'
  import {
    ACCENTS, MONTHS, METRICS, SURFACE_META, shortDid, isoDay, calDays, levelOf, cellColor, parseLinks, timeAgo,
    loadYou, saveProfile, mintToken, revokeToken, registerThisDevice, revokeKey
  } from './you.js'

  const me = $derived(auth.me || { name: 'You', email: 'you@demo', role: 'owner', org: 'demo' })
  const uid = $derived((me.email || 'me').toLowerCase())
  const offline = $derived(auth.offline)

  let profile = $state({})
  let stats = $state({ tokens: 0, runs: 0, runs_ok: 0, agents: 0, shipped: 0, open: 0, first_run: null })
  let activity = $state({ tokens: {}, runs: {}, shipped: {}, agents: {}, verified: {} })
  let contributions = $state([])
  let keys = $state([])
  let tokens = $state([])
  let runtimeDid = $state(null)
  let thisDeviceDid = $state(null)

  let metric = $state('runs')
  let editing = $state(false)
  let saving = $state(false)
  let draft = $state({})
  let tokName = $state('')
  let minting = $state(false)
  let minted = $state(null)
  let toast = $state(null)

  const ACCENT_VAR = (a) => 'var(--color-' + (ACCENTS.includes(a) ? a : 'peach') + ')'

  const displayName = $derived((profile.display && profile.display.trim()) || me.name || (me.email ? me.email.split('@')[0] : 'You'))
  const initial = $derived((displayName[0] || 'Y').toUpperCase())
  const links = $derived(parseLinks(profile.links))
  const memberSince = $derived(stats.first_run ? new Date(stats.first_run * 1000).toLocaleDateString(undefined, { month: 'short', year: 'numeric' }) : null)

  function flash(m) { toast = m; setTimeout(() => (toast === m) && (toast = null), 2200) }

  $effect(() => { uid; load() })
  let booted = false
  async function load() {
    const r = await loadYou(uid, offline)
    profile = r.profile || {}; stats = r.stats || stats; activity = Object.assign({ tokens: {}, runs: {}, shipped: {}, agents: {}, verified: {} }, r.activity)
    contributions = r.contributions || []; keys = r.keys || []; tokens = r.tokens || []; runtimeDid = r.runtime_did || null
    if (!booted) {
      booted = true
      const reg = await registerThisDevice(uid, keys, offline)
      if (reg) { thisDeviceDid = reg.did; if (reg.keys) keys = reg.keys }
    }
  }

  // sub-nav scroll
  let sectionEls = {}
  $effect(() => { const el = sectionEls[ui.youSection]; if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' }) })

  // ── profile edit ──
  function startEdit() {
    editing = true
    draft = { display: profile.display || '', tagline: profile.tagline || '', bio: profile.bio || '', location: profile.location || '', links: profile.links || '', avatar: profile.avatar || '', accent: profile.accent || 'peach' }
  }
  function cancelEdit() { editing = false }
  async function save() {
    saving = true
    try { profile = await saveProfile(uid, draft, offline); editing = false; flash('Profile saved') }
    catch (_) { flash('Could not save') }
    saving = false
  }
  function pickAvatar() {
    if (!editing) startEdit()
    const inp = document.createElement('input'); inp.type = 'file'; inp.accept = 'image/*'
    inp.onchange = () => { const f = inp.files && inp.files[0]; if (!f) return
      if (f.size > 1.5e6) { flash('Image too large — keep it under 1.5 MB'); return }
      const rd = new FileReader(); rd.onload = () => { draft = { ...draft, avatar: rd.result } }; rd.readAsDataURL(f) }
    inp.click()
  }

  // ── tokens ──
  async function mint() {
    minting = true
    try { const r = await mintToken((tokName || '').trim() || 'cli', offline); minted = r.token; tokName = ''
      tokens = [...tokens, { id: r.id || r.token, name: r.name || 'cli' }]; flash('Token generated — copy it now') }
    catch (_) { flash('Could not generate token') }
    minting = false
  }
  async function revoke(id) {
    try { await revokeToken(id, offline); tokens = tokens.filter((t) => t.id !== id); if (minted) minted = null; flash('Token revoked') }
    catch (_) { flash('Could not revoke') }
  }
  async function copyMinted() { try { await navigator.clipboard.writeText(minted); flash('Token copied') } catch (_) {} }

  // ── device keys ──
  async function dropKey(did) {
    try { const k = await revokeKey(uid, did, offline); if (k) keys = k; else keys = keys.map((x) => x.did === did ? { ...x, revoked: 1 } : x); flash('Device key revoked') }
    catch (_) { flash('Could not revoke') }
  }
  const fmtDate = (s) => s ? new Date(s * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) : ''

  // ── heatmap ──
  const days = calDays()
  const weeks = Math.ceil(days.length / 7)
  const metricMeta = $derived(METRICS.find((x) => x.key === metric) || METRICS[0])
  const series = $derived(activity[metric] || {})
  const vser = $derived((activity.verified && activity.verified[metric]) || null)
  const maxVal = $derived(Math.max(1, ...Object.values(series)))
  const totalVal = $derived(Object.values(series).reduce((a, b) => a + b, 0))
  const vtotal = $derived(vser ? Object.values(vser).reduce((a, b) => a + b, 0) : 0)
  function cellTitle(d) {
    const k = isoDay(d), v = series[k] || 0, m = metricMeta
    const human = m.sum ? `${v.toLocaleString()} ${m.noun}` : `${v} ${v === 1 ? m.noun.replace(/s$/, '') : m.noun}`
    const date = MONTHS[d.getMonth()] + ' ' + d.getDate() + ', ' + d.getFullYear()
    return `${human} on ${date}`
  }
  const monthCols = (() => { let last = -1; const out = []
    for (let w = 0; w < weeks; w++) { const f = days[w * 7]; if (f && f.getMonth() !== last) { last = f.getMonth(); out.push(MONTHS[last]) } else out.push('') } return out })()
</script>

<div class="h-full bg-paper flex flex-col min-w-0">
    <div class="flex items-center gap-3 px-6 h-[58px] flex-none border-b border-line">
      <div class="flex-1 min-w-0">
        <div class="font-display font-semibold text-[19px] tracking-tight leading-none">You</div>
        <div class="text-dim text-[12.5px] mt-1">Your profile & what you've built on this nexus</div>
      </div>
    </div>

    <div class="flex-1 overflow-y-auto px-6 py-6">
      <div class="max-w-[820px] flex flex-col gap-5">
        <!-- ── profile ── -->
        <section bind:this={sectionEls.profile} style="scroll-margin-top:12px">
          <div class="rounded-2xl border border-line bg-card p-5 flex gap-5">
            <button onclick={pickAvatar} class="relative w-24 h-24 rounded-3xl flex-none grid place-items-center overflow-hidden border-2 group"
              style="border-color:var(--color-stroke,var(--color-line));background:linear-gradient(135deg,{ACCENT_VAR(editing ? draft.accent : profile.accent)},var(--color-blue,var(--color-sky)))">
              {#if (editing ? draft.avatar : profile.avatar)}
                <img src={editing ? draft.avatar : profile.avatar} alt="" class="w-full h-full object-cover" />
              {:else}
                <span class="font-display font-extrabold text-[34px] text-white">{initial}</span>
              {/if}
              <span class="absolute inset-0 grid place-items-center bg-black/45 text-white text-[12px] font-bold opacity-0 group-hover:opacity-100 transition">{editing ? 'Upload' : 'Change'}</span>
            </button>

            {#if editing}
              <div class="flex-1 min-w-0 flex flex-col gap-2.5">
                {#each [['display','Name',displayName],['tagline','Tagline','What you build, in one line'],['location','Location','San Francisco']] as [k,label,ph]}
                  <label class="flex items-center gap-3"><span class="w-[88px] text-dim text-[13px] flex-none">{label}</span>
                    <input class="flex-1 h-9 px-3 rounded-lg bg-paper border-2 border-line focus:border-ink outline-none text-[14px]" placeholder={ph}
                      value={draft[k]} oninput={(e) => (draft = { ...draft, [k]: e.target.value })} /></label>
                {/each}
                <label class="flex items-start gap-3"><span class="w-[88px] text-dim text-[13px] flex-none mt-2">Bio</span>
                  <textarea class="flex-1 px-3 py-2 rounded-lg bg-paper border-2 border-line focus:border-ink outline-none text-[14px] min-h-[64px] leading-snug" placeholder="A short intro for your team…"
                    value={draft.bio} oninput={(e) => (draft = { ...draft, bio: e.target.value })}></textarea></label>
                <label class="flex items-start gap-3"><span class="w-[88px] text-dim text-[13px] flex-none mt-2">Links</span>
                  <textarea class="flex-1 px-3 py-2 rounded-lg bg-paper border-2 border-line focus:border-ink outline-none text-[14px] min-h-[56px] leading-snug font-mono" placeholder={"GitHub|https://github.com/you\nSite|https://you.dev"}
                    value={draft.links} oninput={(e) => (draft = { ...draft, links: e.target.value })}></textarea></label>
                <label class="flex items-center gap-3"><span class="w-[88px] text-dim text-[13px] flex-none">Accent</span>
                  <div class="flex gap-2 flex-wrap">
                    {#each ACCENTS as a}
                      <button onclick={() => (draft = { ...draft, accent: a })} title={a}
                        class="w-7 h-7 rounded-lg border-2 {draft.accent === a ? 'border-ink' : 'border-transparent'}" style="background:var(--color-{a})"></button>
                    {/each}
                  </div></label>
                <div class="flex justify-end gap-2 mt-1">
                  <button onclick={cancelEdit} class="px-3.5 py-2 rounded-lg border border-line text-[13px] hover:bg-paper">Cancel</button>
                  <button onclick={save} disabled={saving} class="px-3.5 py-2 rounded-lg text-[13px] bg-ink text-paper disabled:opacity-60">{saving ? 'Saving…' : 'Save profile'}</button>
                </div>
              </div>
            {:else}
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2.5 flex-wrap">
                  <span class="font-display font-bold text-[24px] leading-none">{displayName}</span>
                  <span class="px-2 py-0.5 rounded-md text-[10px] font-mono uppercase tracking-wider bg-paper border border-line text-dim capitalize">{me.role}</span>
                  <button onclick={startEdit} class="ml-auto px-3 py-1.5 rounded-lg border border-line text-[12.5px] hover:bg-paper">Edit profile</button>
                </div>
                {#if profile.tagline}<div class="text-dim text-[14px] mt-1.5">{profile.tagline}</div>{:else}<div class="text-dim/60 text-[14px] mt-1.5">Add a tagline — say what you build.</div>{/if}
                {#if profile.bio}<div class="text-[13.5px] leading-relaxed mt-3 whitespace-pre-wrap max-w-[62ch]">{profile.bio}</div>{/if}
                <div class="flex gap-4 flex-wrap mt-3.5 text-dim text-[12.5px]">
                  <span class="text-ink font-semibold">{me.email}</span>
                  {#if profile.location}<span>📍 {profile.location}</span>{/if}
                  {#if memberSince}<span>Active since <b class="text-ink">{memberSince}</b></span>{/if}
                </div>
                {#if links.length}
                  <div class="flex gap-2 flex-wrap mt-3">
                    {#each links as l}<a href={l.url} target="_blank" rel="noopener" class="inline-flex items-center gap-1.5 px-3 py-1 rounded-full border-[1.5px] border-line text-[12.5px] hover:border-ink">🔗 {l.label}</a>{/each}
                  </div>
                {/if}
              </div>
            {/if}
          </div>
        </section>

        <!-- ── contributions: heatmap + list ── -->
        <section bind:this={sectionEls.contributions} style="scroll-margin-top:12px">
          <div class="rounded-2xl border border-line bg-card p-5" style="--you-empty:color-mix(in srgb,var(--color-ink) 7%,transparent)">
            <div class="flex items-center justify-between gap-3 flex-wrap mb-3.5">
              <div class="text-[13.5px]"><b>{metricMeta.sum ? totalVal.toLocaleString() : totalVal}</b> <span class="text-dim">{metricMeta.noun} in the last year</span>
                {#if vser && totalVal > 0}<span class="ml-2 text-[11.5px] px-2 py-0.5 rounded-full border-[1.5px]" style="color:var(--color-mint);border-color:var(--color-mint)" title="Metering counter-signed by this nexus">🔒 {vtotal} verified</span>{/if}
              </div>
              <div class="flex gap-1.5 flex-wrap">
                {#each METRICS as x}
                  <button onclick={() => (metric = x.key)}
                    class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full border-[1.5px] text-[12px] font-semibold transition
                      {x.key === metric ? 'text-ink' : 'text-dim border-line hover:text-ink hover:border-ink'}"
                    style:border-color={x.key === metric ? x.acc : ''} style:background={x.key === metric ? `color-mix(in srgb,${x.acc} 14%,transparent)` : ''}>
                    <span class="w-2.5 h-2.5 rounded-sm" style="background:{x.acc}"></span>{x.label}</button>
                {/each}
              </div>
            </div>
            <div class="grid" style="grid-template-columns:auto 1fr;column-gap:9px;--gap:4px">
              <div class="col-start-2 grid" style="min-width:0;grid-auto-flow:column;grid-auto-columns:1fr;column-gap:var(--gap);font-size:10.5px;color:var(--color-dim);margin-bottom:6px">
                {#each monthCols as m}<span class="whitespace-nowrap">{m}</span>{/each}
              </div>
              <div class="col-start-1 row-start-2 grid" style="grid-template-rows:repeat(7,1fr);gap:var(--gap);font-size:10px;color:var(--color-dim);padding-right:2px">
                {#each ['', 'Mon', '', 'Wed', '', 'Fri', ''] as l}<span class="flex items-center">{l}</span>{/each}
              </div>
              <div class="col-start-2 row-start-2 grid" style="min-width:0;grid-auto-flow:column;grid-auto-columns:1fr;grid-template-rows:repeat(7,1fr);gap:var(--gap);aspect-ratio:{weeks} / 7">
                {#each days as d}
                  {@const k = isoDay(d)}
                  {@const lvl = levelOf(series[k] || 0, maxVal)}
                  {@const vc = vser ? (vser[k] || 0) : 0}
                  <span class="rounded-[3px]" title={cellTitle(d)} style="background:{cellColor(lvl, metricMeta.acc)}{vc > 0 ? ';box-shadow:inset 0 0 0 1.5px var(--color-ink)' : ''}"></span>
                {/each}
              </div>
            </div>
            <div class="flex items-center gap-1.5 justify-end text-[10.5px] text-dim mt-3">Less {#each [0, 1, 2, 3, 4] as l}<i class="w-3 h-3 rounded-[3px] inline-block" style="background:{cellColor(l, metricMeta.acc)}"></i>{/each} More</div>
          </div>

          <div class="rounded-2xl border border-line bg-card p-5 mt-3.5">
            <div class="font-display font-semibold text-[15px]">Contributions</div>
            <div class="text-dim text-[12.5px] mt-0.5 mb-3">The systems you authored on this nexus — what shipped, and what's in flight.</div>
            {#if contributions.length}
              {#each contributions as c}
                <div class="flex items-center gap-3 py-2.5 border-b border-line last:border-0">
                  <span class="w-2.5 h-2.5 rounded-full flex-none" style="background:{c.status === 'done' ? 'var(--color-mint)' : c.status === 'in_progress' ? 'var(--color-sky)' : 'var(--color-line)'}"></span>
                  <div class="flex-1 min-w-0">
                    <div class="text-[13.5px] truncate">{c.title || c.tid}</div>
                    <div class="text-dim text-[11.5px] mt-0.5">{c.kind}{c.agent ? ` · ${c.agent}` : ''}{c.updated ? ` · ${timeAgo(c.updated)}` : ''}</div>
                  </div>
                  <span class="text-[10px] font-mono uppercase tracking-wider px-2 py-1 rounded-md border-[1.5px] flex-none" style="color:{c.status === 'done' ? 'var(--color-mint)' : 'var(--color-dim)'};border-color:{c.status === 'done' ? 'var(--color-mint)' : 'var(--color-line)'}">{(c.status || 'open').replace('_', ' ')}</span>
                </div>
              {/each}
            {:else}
              <div class="text-dim/70 text-[13px] py-3">Nothing authored yet. Work you file or dispatch from Studio shows up here — and what ships gets a ✓.</div>
            {/if}
          </div>
        </section>

        <!-- ── usage ── -->
        <section bind:this={sectionEls.usage} style="scroll-margin-top:12px">
          <div class="rounded-2xl border border-line bg-card p-5">
            <div class="font-display font-semibold text-[15px]">Usage</div>
            <div class="text-dim text-[12.5px] mt-0.5 mb-3">Your footprint on this nexus. Org-wide billing & limits live in Admin.</div>
            {#each [['Tokens used', (stats.tokens || 0).toLocaleString()], ['Runs launched', `${stats.runs || 0} (${stats.runs_ok || 0} ok)`], ['Avg tokens / run', stats.runs ? Math.round(stats.tokens / stats.runs).toLocaleString() : '—'], ['Agents driven', String(stats.agents || 0)], ['🔒 Verified metering', `${stats.verified_runs || 0} of ${stats.runs || 0} runs · ${(stats.verified_tokens || 0).toLocaleString()} tokens counter-signed`]] as [k, v]}
              <div class="flex items-center justify-between py-2 border-b border-line last:border-0 text-[13.5px]"><span class="text-dim">{k}</span><span>{v}</span></div>
            {/each}
            {#if runtimeDid}<div class="flex items-center justify-between py-2 text-[13.5px] gap-3"><span class="text-dim">Attested by</span><span class="font-mono text-[11px] truncate">{runtimeDid}</span></div>{/if}
          </div>
        </section>

        <!-- ── CLI access ── -->
        <section bind:this={sectionEls.cli} style="scroll-margin-top:12px">
          <div class="rounded-2xl border border-line bg-card p-5">
            <div class="font-display font-semibold text-[15px]">CLI access</div>
            <div class="text-dim text-[12.5px] mt-0.5 mb-3.5">Tokens let the <code class="font-mono text-ink">work</code> CLI act as you, headless — <code class="font-mono text-ink">work login --token &lt;token&gt;</code>.</div>

            <!-- create — a single sleek composer: input fills, the action sits inline on the right -->
            <div class="flex items-center gap-1 h-11 pl-3.5 pr-1 rounded-xl bg-paper border border-line focus-within:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))] transition">
              <input class="flex-1 min-w-0 bg-transparent outline-none text-[14px] placeholder:text-dim/70" placeholder="Name a new token — e.g. my-laptop" value={tokName} oninput={(e) => (tokName = e.target.value)} onkeydown={(e) => e.key === 'Enter' && mint()} />
              <button onclick={mint} disabled={minting} title="Generate token"
                class="flex items-center gap-1.5 px-3 h-8 rounded-lg text-[12.5px] font-semibold bg-ink text-paper disabled:opacity-50 flex-none whitespace-nowrap [&>svg]:w-[13px] [&>svg]:h-[13px]">
                {@html iconSvgByName('plus', 13)}{minting ? 'Generating…' : 'New token'}</button>
            </div>

            <!-- freshly minted: a one-time reveal callout -->
            {#if minted}
              <div class="mt-3 rounded-xl p-3.5" style="background:color-mix(in srgb,var(--color-mint) 9%,transparent);border:1px solid color-mix(in srgb,var(--color-mint) 35%,var(--color-line))">
                <div class="text-[12px] font-semibold mb-1.5" style="color:var(--color-mint)">Copy it now — you won't see this token again.</div>
                <div class="flex items-center gap-2">
                  <code class="font-mono text-[12.5px] flex-1 min-w-0 truncate px-2.5 py-1.5 rounded-lg bg-paper border border-line">{minted}</code>
                  <button onclick={copyMinted} class="px-3 h-8 rounded-lg text-[12px] font-semibold bg-ink text-paper flex-none">Copy</button>
                </div>
              </div>
            {/if}

            <!-- active tokens -->
            {#if tokens.length}
              <div class="text-[11px] font-mono uppercase tracking-wider text-dim mt-4 mb-1">Active tokens · {tokens.length}</div>
              {#each tokens as t}
                <CredRow icon="terminal" tint="var(--color-sky)" title={t.name} fingerprint={t.id} onRevoke={() => revoke(t.id)} />
              {/each}
            {:else}
              <div class="text-dim/70 text-[13px] mt-3">No tokens yet. Generate one to drive the CLI as you.</div>
            {/if}
          </div>
        </section>

        <!-- ── devices & keys ── -->
        <section bind:this={sectionEls.devices} style="scroll-margin-top:12px">
          <div class="rounded-2xl border border-line bg-card p-5">
            <div class="font-display font-semibold text-[15px]">Devices & keys</div>
            <div class="text-dim text-[12.5px] mt-0.5 mb-1">One identity, many signing keys — each device you sign from holds its own. Anything signed by any of them is provably yours; revoke one without touching your identity.</div>
            {#each keys.filter((k) => !k.revoked) as k}
              {@const sm = SURFACE_META[k.surface] || { label: 'Device', icon: 'key', tint: 'var(--color-dim)' }}
              <CredRow icon={sm.icon} tint={sm.tint}
                title={`${sm.label}${k.label ? ` · ${k.label}` : ''}`}
                badge={k.did === thisDeviceDid ? 'this device' : ''}
                fingerprint={shortDid(k.did)} copyValue={k.did}
                meta={k.registered ? `added ${fmtDate(k.registered)}` : ''}
                onRevoke={() => dropKey(k.did)} />
            {:else}
              <div class="text-dim/70 text-[13px] mt-2">No device keys yet. This browser registers one automatically; the CLI registers its own when you <code class="font-mono">work login</code>.</div>
            {/each}
          </div>
        </section>

        <!-- ── preferences ── -->
        <section bind:this={sectionEls.prefs} style="scroll-margin-top:12px">
          <div class="rounded-2xl border border-line bg-card p-5">
            <div class="font-display font-semibold text-[15px]">Preferences</div>
            <div class="text-dim text-[12.5px] mt-0.5 mb-3">How the dashboard looks & behaves for you.</div>
            <div class="flex items-center justify-between py-1">
              <span class="text-[13.5px] text-dim">Appearance</span>
              <div class="flex gap-2">
                {#each [{ id: 'dark', label: 'Dark', icon: 'half-moon' }, { id: 'light', label: 'Light', icon: 'sun-light' }] as t}
                  <button onclick={() => setTheme(t.id)} class="flex items-center gap-2 rounded-xl border px-3.5 py-2 text-left transition [&>span>svg]:w-[15px] [&>span>svg]:h-[15px]"
                    style="border-color:{ui.theme === t.id ? 'color-mix(in srgb,var(--color-sky) 60%,var(--color-line))' : 'var(--color-line)'};background:{ui.theme === t.id ? 'color-mix(in srgb,var(--color-sky) 10%,transparent)' : 'transparent'}">
                    <span class="grid place-items-center text-dim">{@html iconSvgByName(t.icon, 15)}</span><span class="text-[13.5px]">{t.label}</span></button>
                {/each}
              </div>
            </div>
            <div class="flex items-center justify-between gap-4 pt-3.5 mt-2 border-t border-line">
              <span class="text-dim text-[12.5px]">Done for now? Sign out of this device.</span>
              <button onclick={logout} class="px-3.5 py-2 rounded-lg border border-line text-[13px] hover:bg-paper" style="color:var(--color-bad)">Sign out</button>
            </div>
          </div>
        </section>
      </div>
    </div>
  </div>

{#if toast}<div class="fixed bottom-5 left-1/2 -translate-x-1/2 px-4 py-2.5 rounded-xl bg-ink text-paper text-[13px] shadow-lg z-50">{toast}</div>{/if}
