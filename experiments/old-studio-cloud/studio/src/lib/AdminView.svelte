<script>
  // AdminView — a default, undeletable admin page (nexus-wide operations). Renders the real control-plane
  // data for its page (secrets/env · members · domains · fleet · usage). Read-first; write actions land in a
  // follow pass. Admin-role only (the surface is only synthesized for admins).
  import { surfaceById } from './data.svelte.js'
  import { auth } from './auth.svelte.js'
  import { loadAdmin, inviteMember, removeMember, revokeInvite,
    addSecret, rotateSecret, deleteSecret, addDomain, verifyDomain, removeDomain,
    changePlan, topUp, mintToken, revokeToken,
    saveProfile, revokeKey, setVisibility, cancelSchedule, deleteWorkspaceCP } from './admin.js'
  import { runAction, askConfirm, copyText, roleColor, statusColor, rank, ROLES } from './adminkit.svelte.js'
  import { pushToast } from './toast.svelte.js'
  import { iconSvgByName } from './icons.js'
  import Pill from './Pill.svelte'
  import CopyBtn from './CopyBtn.svelte'

  let { surfaceId } = $props()
  const s = $derived(surfaceById(surfaceId))
  const page = $derived(s?.payload?.page || 'members')

  let data = $state(null)
  $effect(() => { const p = page; data = null; loadAdmin(p, auth.offline).then((d) => (data = d)) })
  async function reload() { data = await loadAdmin(page, auth.offline) }

  // caller authz — mirror the server rank so the UI only offers what the backend will accept
  const myRank = $derived(rank(auth.me?.role))
  const assignableRoles = $derived(ROLES.filter((r) => rank(r) <= myRank)) // can't grant above your own rank

  // ── Members ──────────────────────────────────────────────────────────────────────────────────────
  let inviteEmail = $state('')
  let inviteRole = $state('member')
  let busy = $state(false)

  async function doInvite() {
    if (!inviteEmail.trim() || busy) return
    busy = true
    const r = await runAction(() => inviteMember(inviteEmail.trim(), inviteRole), { success: `Invited ${inviteEmail.trim()}` })
    busy = false
    if (r) { inviteEmail = ''; await reload() }
  }
  async function doRemove(m) {
    const ok = await askConfirm({ title: `Remove ${m.name || m.email}?`, body: `They lose access to this nexus immediately.`, confirmLabel: 'Remove', danger: true, typed: m.email })
    if (!ok) return
    if (await runAction(() => removeMember(m.id), { success: `Removed ${m.name || m.email}` })) await reload()
  }
  async function doRevoke(p) {
    if (await runAction(() => revokeInvite(p.id), { success: `Revoked invite for ${p.email}` })) await reload()
  }
  async function doResend(p) {
    if (await runAction(() => inviteMember(p.email, p.role || 'member'), { success: `Re-sent invite to ${p.email}` })) await reload()
  }
  // last owner can't be removed; you can't act on someone ranked above you
  const owners = $derived((data?.members || []).filter((m) => m.role === 'owner').length)
  const canManage = (m) => rank(m.role) <= myRank && !(m.role === 'owner' && owners <= 1)

  // ── Secrets (write-only: add / rotate / delete; values never read back) ──────────────────────────
  let secName = $state(''), secValue = $state(''), secScope = $state('nexus')
  async function doAddSecret() {
    if (!secName.trim() || !secValue || busy) return
    busy = true
    const r = await runAction(() => addSecret(secName.trim(), secValue, secScope), { success: `Saved ${secName.trim()}` })
    busy = false
    if (r) { secName = ''; secValue = ''; await reload() }
  }
  async function doDeleteSecret(e) {
    if (await askConfirm({ title: `Delete ${e.name}?`, body: 'Anything using this secret will break.', confirmLabel: 'Delete', danger: true, typed: e.name }))
      if (await runAction(() => deleteSecret(e.id), { success: `Deleted ${e.name}` })) await reload()
  }

  // ── Domains (add → DNS challenge → verify → remove) ──────────────────────────────────────────────
  let newDomain = $state('')
  async function doAddDomain() {
    if (!newDomain.trim() || busy) return
    busy = true
    const r = await runAction(() => addDomain(newDomain.trim().toLowerCase()), { success: `Added ${newDomain.trim()}` })
    busy = false
    if (r) { newDomain = ''; await reload() }
  }
  async function doVerify(d) { if (await runAction(() => verifyDomain(d.id), { success: `Verifying ${d.host}…` })) await reload() }
  async function doRemoveDomain(d) {
    if (await askConfirm({ title: `Remove ${d.host}?`, body: `Traffic to <b>${d.host}</b> will stop. Delete its DNS records at your registrar too.`, confirmLabel: 'Remove', danger: true, typed: d.host }))
      if (await runAction(() => removeDomain(d.id), { success: `Removed ${d.host}` })) await reload()
  }

  // ── Usage gauges ─────────────────────────────────────────────────────────────────────────────────
  const u = $derived(data?.usage || {})
  const gaugeColor = (st) => st === 'over' || st === 'error' ? 'var(--color-bad)' : st === 'near' ? 'var(--color-amber)' : 'var(--color-mint)'

  // ── Billing ──────────────────────────────────────────────────────────────────────────────────────
  let topupAmt = $state(20)
  const inf = $derived(data?.inference || {})
  const spendPct = $derived(inf.monthly_cap ? Math.min(100, ((inf.spent_mtd || 0) / inf.monthly_cap) * 100) : 0)
  async function doChangePlan(tier) {
    if (!await askConfirm({ title: `Change plan to ${tier}?`, body: 'You\'ll be taken to checkout to confirm.', confirmLabel: 'Continue' })) return
    const r = await runAction(() => changePlan(tier))
    if (r?.url) window.location.href = r.url
    else if (r?.pending) pushToast('Billing isn\'t set up on this nexus yet', 'info')
  }
  async function doTopup() {
    const total = (topupAmt * 1.055).toFixed(2)
    if (!await askConfirm({ title: `Top up $${topupAmt}?`, body: `You pay <b>$${total}</b> (incl. fees) and receive <b>$${topupAmt}</b> credit.`, confirmLabel: 'Continue to checkout' })) return
    const r = await runAction(() => topUp(topupAmt))
    if (r?.url) window.location.href = r.url
    else if (r?.pending) pushToast('Billing isn\'t set up on this nexus yet', 'info')
  }

  // ── API Tokens ───────────────────────────────────────────────────────────────────────────────────
  let tokName = $state(''), tokRole = $state('member'), minted = $state(null)
  async function doMint() {
    if (!tokName.trim() || busy) return
    busy = true
    const r = await runAction(() => mintToken(tokName.trim(), tokRole), { success: 'Token created' })
    busy = false
    if (r) { minted = r.token || r.value || r.secret || null; tokName = ''; await reload() }
  }
  async function doRevokeToken(t) {
    if (await askConfirm({ title: `Revoke "${t.name}"?`, body: 'Any client using this token loses access immediately.', confirmLabel: 'Revoke', danger: true }))
      if (await runAction(() => revokeToken(t.id), { success: `Revoked ${t.name}` })) await reload()
  }
  const ago = (ts) => { if (!ts) return 'never'; const d = (Date.now() / 1000 - ts) / 86400; return d < 1 ? 'today' : Math.floor(d) + 'd ago' }

  // ── Profile / Security / Visibility / Schedules / Danger ─────────────────────────────────────────
  let pform = $state({ display: '', tagline: '', location: '', links: '' })
  $effect(() => { const p = data?.profile; if (p) pform = { display: p.display || '', tagline: p.tagline || '', location: p.location || '', links: p.links || '' } })
  async function doSaveProfile() { await runAction(() => saveProfile(pform), { success: 'Profile saved' }) }
  async function doRevokeKey(k) {
    if (await askConfirm({ title: `Revoke device key?`, body: 'That device will need to re-authenticate.', confirmLabel: 'Revoke', danger: true }))
      if (await runAction(() => revokeKey(k.id), { success: 'Device key revoked' })) await reload()
  }
  async function doSetVisibility(w, state) {
    if (await runAction(() => setVisibility(w.id, state), { success: `${w.name || w.id} is now ${state}` })) await reload()
  }
  async function doCancelSchedule(sc) {
    if (await askConfirm({ title: 'Cancel this schedule?', confirmLabel: 'Cancel it', danger: true }))
      if (await runAction(() => cancelSchedule(sc.id), { success: 'Schedule canceled' })) await reload()
  }
  async function doDeleteWorkspace(w) {
    if (await askConfirm({ title: `Delete workspace ${w.name || w.id}?`, body: 'All its content is removed. This cannot be undone.', confirmLabel: 'Delete forever', danger: true, typed: w.id }))
      if (await runAction(() => deleteWorkspaceCP(w.id), { success: `Deleted ${w.name || w.id}` })) await reload()
  }
  const VIS = ['public', 'private', 'draft']
</script>

<div class="h-full overflow-y-auto" style="background:var(--color-paper)">
  <div class="max-w-[920px] mx-auto px-7 py-7">
    <div class="flex items-center gap-2.5 mb-1">
      <span class="grid place-items-center text-ink [&>svg]:w-[18px] [&>svg]:h-[18px]">{@html iconSvgByName(s?.icon || 'settings', 18)}</span>
      <h1 class="font-display font-semibold text-[20px] tracking-tight">{s?.name || 'Admin'}</h1>
      <span class="text-[10px] font-mono uppercase tracking-wider px-1.5 py-0.5 rounded-md border border-line text-dim">system</span>
    </div>
    <div class="text-dim text-[13px] mb-5">Nexus-wide — affects the whole nexus. Admin only.</div>

    {#if !data}
      <div class="text-dim/70 text-[13px] py-6">Loading…</div>
    {:else if data.error}
      <div class="text-[13px] py-6" style="color:var(--color-bad)">Couldn’t load — {data.error}</div>
    {:else if page === 'secrets'}
      <!-- add (write-only: set the value once, never read back) -->
      <form onsubmit={(e) => { e.preventDefault(); doAddSecret() }} class="flex items-center gap-2 mb-2">
        <input bind:value={secName} placeholder="NAME" class="w-[34%] bg-card border border-line rounded-xl px-3 py-2 text-[13px] font-mono outline-none focus:border-ink" />
        <input bind:value={secValue} type="password" placeholder="value" autocomplete="off" class="flex-1 bg-card border border-line rounded-xl px-3 py-2 text-[13px] font-mono outline-none focus:border-ink" />
        <select bind:value={secScope} class="appearance-none bg-card border border-line rounded-xl px-3 py-2 text-[13px] outline-none focus:border-ink cursor-pointer">
          <option value="nexus">nexus</option><option value="workspace">workspace</option><option value="user">user</option>
        </select>
        <button type="submit" disabled={busy || !secName.trim() || !secValue} class="px-3.5 py-2 rounded-xl text-[13px] font-medium disabled:opacity-40" style="background:var(--color-ink);color:var(--color-paper)">Save</button>
      </form>
      {#if secScope === 'nexus'}<div class="text-[11px] text-dim/70 mb-4">⚠ <span class="text-amber">nexus</span> scope is visible to the whole nexus.</div>{:else}<div class="mb-4"></div>{/if}
      <div class="rounded-2xl border border-line bg-card divide-y divide-line">
        {#each data.env as e}
          <div class="group flex items-center gap-3 px-4 py-2.5 text-[13px]">
            <span class="grid place-items-center text-dim/50 [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('lock', 12)}</span>
            <span class="font-mono text-ink flex-1 truncate">{e.name}</span>
            <span class="font-mono text-dim/40 text-[12px] select-none">{e.masked || '••••••••'}</span>
            <Pill label={e.scope || 'nexus'} color={e.scope === 'nexus' ? 'var(--color-amber)' : 'var(--color-dim)'} />
            <button onclick={() => doDeleteSecret(e)} title="Delete" class="opacity-0 group-hover:opacity-100 transition-opacity text-dim hover:text-[var(--color-bad)] [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('trash', 14)}</button>
          </div>
        {:else}<div class="px-4 py-8 text-center text-dim/70 text-[13px]">No secrets yet — add your first above.</div>{/each}
      </div>
      <div class="text-[11px] text-dim/60 mt-2.5">Secrets are write-only — set or replace a value, but it's never shown again (rotate by re-saving the same name).</div>
    {:else if page === 'members'}
      <!-- invite -->
      <form onsubmit={(e) => { e.preventDefault(); doInvite() }} class="flex items-center gap-2 mb-5">
        <input bind:value={inviteEmail} type="email" placeholder="teammate@email.com"
          class="flex-1 bg-card border border-line rounded-xl px-3.5 py-2 text-[13px] outline-none focus:border-ink" />
        <div class="relative">
          <select bind:value={inviteRole} class="appearance-none bg-card border border-line rounded-xl pl-3 pr-7 py-2 text-[13px] outline-none focus:border-ink cursor-pointer">
            {#each assignableRoles as r}<option value={r}>{r}</option>{/each}
          </select>
          <span class="absolute right-2 top-1/2 -translate-y-1/2 pointer-events-none text-dim [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('nav-arrow-down', 12)}</span>
        </div>
        <button type="submit" disabled={busy || !inviteEmail.trim()} class="px-3.5 py-2 rounded-xl text-[13px] font-medium disabled:opacity-40" style="background:var(--color-ink);color:var(--color-paper)">{busy ? 'Inviting…' : 'Invite'}</button>
      </form>

      <!-- members -->
      <div class="text-[10px] font-mono uppercase tracking-wider text-dim/60 mb-1.5">Members ({data.members.length})</div>
      <div class="rounded-2xl border border-line bg-card divide-y divide-line mb-5">
        {#each data.members as m}
          <div class="group flex items-center gap-3 px-4 py-2.5 text-[13px]">
            <span class="flex-1 truncate">{m.name || m.email}{#if m.email === auth.me?.email}<span class="text-dim/70 text-[11px]"> · you</span>{/if}{#if m.name}<span class="text-dim/70"> · {m.email}</span>{/if}</span>
            <Pill label={m.role} color={roleColor(m.role)} />
            {#if canManage(m) && m.email !== auth.me?.email}
              <button onclick={() => doRemove(m)} title="Remove" class="opacity-0 group-hover:opacity-100 transition-opacity text-dim hover:text-[var(--color-bad)] [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('trash', 14)}</button>
            {/if}
          </div>
        {:else}<div class="px-4 py-8 text-center text-dim/70 text-[13px]">No teammates yet — invite someone above.</div>{/each}
      </div>

      <!-- pending invites -->
      {#if (data.pending || []).length}
        <div class="text-[10px] font-mono uppercase tracking-wider text-dim/60 mb-1.5">Pending invites ({data.pending.length})</div>
        <div class="rounded-2xl border border-line bg-card divide-y divide-line">
          {#each data.pending as p}
            <div class="group flex items-center gap-3 px-4 py-2.5 text-[13px]">
              <span class="flex-1 truncate text-dim">{p.email}</span>
              <Pill label={p.role || 'member'} color={roleColor(p.role || 'member')} />
              <button onclick={() => doResend(p)} class="opacity-0 group-hover:opacity-100 transition-opacity text-[11px] px-2 py-0.5 rounded-md border border-line text-dim hover:text-ink">Resend</button>
              <button onclick={() => doRevoke(p)} class="opacity-0 group-hover:opacity-100 transition-opacity text-[11px] px-2 py-0.5 rounded-md border border-line text-dim hover:text-[var(--color-bad)]">Revoke</button>
            </div>
          {/each}
        </div>
      {/if}
    {:else if page === 'domains'}
      <form onsubmit={(e) => { e.preventDefault(); doAddDomain() }} class="flex items-center gap-2 mb-5">
        <input bind:value={newDomain} placeholder="app.yourdomain.com" class="flex-1 bg-card border border-line rounded-xl px-3.5 py-2 text-[13px] font-mono outline-none focus:border-ink" />
        <button type="submit" disabled={busy || !newDomain.trim()} class="px-3.5 py-2 rounded-xl text-[13px] font-medium disabled:opacity-40" style="background:var(--color-ink);color:var(--color-paper)">Add domain</button>
      </form>
      <div class="flex flex-col gap-2.5">
        {#each data.domains as d}
          <div class="rounded-2xl border border-line bg-card overflow-hidden">
            <div class="flex items-center gap-3 px-4 py-2.5 text-[13px]">
              <span class="flex-1 font-mono truncate">{d.host}</span>
              <Pill label={d.status || 'pending'} color={statusColor(d.status)} />
              {#if d.status !== 'active' && d.status !== 'verified'}<button onclick={() => doVerify(d)} class="text-[11px] px-2 py-0.5 rounded-md border border-line text-dim hover:text-ink">Verify</button>{/if}
              <button onclick={() => doRemoveDomain(d)} title="Remove" class="text-dim hover:text-[var(--color-bad)] [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('trash', 14)}</button>
            </div>
            {#if d.verify || d.cname}
              <div class="border-t border-line px-4 py-3 bg-paper/40">
                <div class="text-[10px] font-mono uppercase tracking-wider text-dim/60 mb-2">Add these DNS records</div>
                {#each [d.verify && { ...d.verify, kind: d.verify.type || 'TXT' }, d.cname && { kind: 'CNAME', name: d.cname.name, value: d.cname.target }].filter(Boolean) as rec}
                  <div class="flex items-center gap-2 text-[12px] font-mono py-1">
                    <span class="w-[48px] text-dim shrink-0">{rec.kind}</span>
                    <span class="text-dim/80 truncate max-w-[18ch]">{rec.name}</span>
                    <span class="text-ink truncate flex-1">{rec.value}</span>
                    <CopyBtn text={rec.value} />
                  </div>
                {/each}
              </div>
            {/if}
          </div>
        {:else}<div class="rounded-2xl border border-line bg-card px-4 py-8 text-center text-dim/70 text-[13px]">No custom domains. Serve your apps from your own domain — add one above.</div>{/each}
      </div>
    {:else if page === 'usage'}
      {#if u.tier}<div class="flex items-center gap-2 mb-4"><span class="font-display font-semibold text-[15px]">{u.tier.name} plan</span><span class="text-dim text-[12.5px]">{Math.round((u.tier.ram_mb||0)/1024)} GB RAM · {u.tier.storage_gb} GB storage{#if u.tier.domains} · custom domains{/if}</span></div>{/if}
      <div class="rounded-2xl border border-line bg-card p-5 flex flex-col gap-4">
        {#each [['RAM', u.ram], ['Storage', u.storage]] as [label, g]}
          {#if g}
            <div>
              <div class="flex items-center justify-between text-[12.5px] mb-1.5"><span class="text-dim">{label}{#if label === 'RAM' && u.load != null} · {u.load}% load{/if}</span><span class="font-mono text-ink/80">{g.label}</span></div>
              <div class="h-[8px] rounded-full bg-[color-mix(in_srgb,var(--color-ink)_7%,transparent)] overflow-hidden"><div class="h-full rounded-full transition-all" style="width:{Math.min(100, g.pct || 0)}%;background:{gaugeColor(g.status)}"></div></div>
            </div>
          {/if}
        {/each}
        {#if u.activeHrs != null}<div class="flex items-center justify-between text-[12.5px] pt-1 border-t border-line"><span class="text-dim">Active this month</span><span class="font-mono text-ink/80">{u.activeHrs} hrs</span></div>{/if}
      </div>
      {#if (data.storage?.buckets || []).length}
        <div class="text-[10px] font-mono uppercase tracking-wider text-dim/60 mt-5 mb-1.5">Storage by surface</div>
        <div class="rounded-2xl border border-line bg-card divide-y divide-line">
          {#each data.storage.buckets as b}<div class="flex items-center gap-3 px-4 py-2 text-[13px]"><span class="flex-1 font-mono truncate">{b.name}</span><span class="text-dim/70 text-[11px]">{b.objects} objects</span><span class="font-mono text-ink/80">{b.size}</span></div>{/each}
        </div>
      {/if}
    {:else if page === 'billing'}
      <!-- plan -->
      <div class="rounded-2xl border border-line bg-card p-5 mb-4">
        <div class="text-[10px] font-mono uppercase tracking-wider text-dim/60 mb-2">Plan</div>
        {#if data.billing?.subscription}
          <div class="flex items-center gap-2 mb-3"><span class="font-display font-semibold text-[16px]">{data.billing.subscription.tier}</span><Pill label={data.billing.subscription.status || 'active'} color={statusColor(data.billing.subscription.status)} /></div>
        {:else}
          <div class="text-[13px] text-dim mb-3">No plan yet — choose one to scale your machine.</div>
        {/if}
        <div class="flex flex-wrap gap-2">
          {#each data.tiers as t}
            <button onclick={() => doChangePlan(t.id)} class="flex-1 min-w-[120px] text-left rounded-xl border border-line px-3 py-2.5 hover:border-ink transition-colors">
              <div class="text-[13px] font-medium">{t.name}</div>
              <div class="text-[11px] text-dim">{Math.round((t.ram_mb||0)/1024)} GB · {t.storage_gb} GB · <span class="font-mono">{t.price}</span></div>
            </button>
          {/each}
        </div>
        {#if data.billing && !data.billing.configured}<div class="text-[11px] text-dim/60 mt-3">Billing isn't set up on this nexus yet.</div>{/if}
      </div>
      <!-- credit -->
      <div class="rounded-2xl border border-line bg-card p-5">
        <div class="text-[10px] font-mono uppercase tracking-wider text-dim/60 mb-2">Inference credit</div>
        <div class="flex items-end justify-between mb-3">
          <span class="font-display font-semibold text-[24px]">${(inf.balance ?? 0).toFixed(2)}</span>
          <div class="flex items-center gap-2">
            <span class="text-dim text-[12px]">$</span>
            <input type="number" bind:value={topupAmt} min="5" class="w-[70px] bg-paper border border-line rounded-lg px-2 py-1.5 text-[13px] font-mono outline-none focus:border-ink" />
            <button onclick={doTopup} class="px-3 py-1.5 rounded-lg text-[13px] font-medium" style="background:var(--color-ink);color:var(--color-paper)">Top up</button>
          </div>
        </div>
        {#if inf.monthly_cap}
          <div class="flex items-center justify-between text-[12px] mb-1.5"><span class="text-dim">Spent this month</span><span class="font-mono text-ink/80">${(inf.spent_mtd||0).toFixed(2)} / ${inf.monthly_cap.toFixed(2)}</span></div>
          <div class="h-[7px] rounded-full bg-[color-mix(in_srgb,var(--color-ink)_7%,transparent)] overflow-hidden"><div class="h-full rounded-full" style="width:{spendPct}%;background:{spendPct>=100?'var(--color-bad)':spendPct>=80?'var(--color-amber)':'var(--color-mint)'}"></div></div>
        {:else}
          <div class="text-[12px] text-dim">Spent ${(inf.spent_mtd||0).toFixed(2)} this month · no cap set.</div>
        {/if}
      </div>
    {:else if page === 'tokens'}
      <form onsubmit={(e) => { e.preventDefault(); doMint() }} class="flex items-center gap-2 mb-3">
        <input bind:value={tokName} placeholder="token name (e.g. mac, ci)" class="flex-1 bg-card border border-line rounded-xl px-3.5 py-2 text-[13px] outline-none focus:border-ink" />
        <select bind:value={tokRole} class="appearance-none bg-card border border-line rounded-xl px-3 py-2 text-[13px] outline-none focus:border-ink cursor-pointer">
          {#each assignableRoles as r}<option value={r}>{r}</option>{/each}
        </select>
        <button type="submit" disabled={busy || !tokName.trim()} class="px-3.5 py-2 rounded-xl text-[13px] font-medium disabled:opacity-40" style="background:var(--color-ink);color:var(--color-paper)">Create</button>
      </form>
      {#if minted}
        <div class="rounded-2xl border p-4 mb-3" style="border-color:var(--color-mint);background:color-mix(in srgb,var(--color-mint) 8%,transparent)">
          <div class="text-[12px] text-dim mb-1.5">Copy this token now — it won't be shown again.</div>
          <div class="flex items-center gap-2"><span class="flex-1 font-mono text-[12.5px] text-ink truncate">{minted}</span><button onclick={() => { copyText(minted); minted = null }} class="text-[11px] px-2 py-1 rounded-md border border-line text-ink">Copy & dismiss</button></div>
        </div>
      {/if}
      <div class="rounded-2xl border border-line bg-card divide-y divide-line">
        {#each data.tokens as t}
          <div class="group flex items-center gap-3 px-4 py-2.5 text-[13px]">
            <span class="flex-1 truncate">{t.name}</span>
            <span class="text-dim/60 text-[11px]">last used {ago(t.last_used_at)}</span>
            <Pill label={t.role} color={roleColor(t.role)} />
            <button onclick={() => doRevokeToken(t)} title="Revoke" class="opacity-0 group-hover:opacity-100 transition-opacity text-dim hover:text-[var(--color-bad)] [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('trash', 14)}</button>
          </div>
        {:else}<div class="px-4 py-8 text-center text-dim/70 text-[13px]">No tokens — create one to use the <span class="font-mono">work</span> CLI or API.</div>{/each}
      </div>
    {:else if page === 'audit'}
      <div class="rounded-2xl border border-line bg-card divide-y divide-line">
        {#each data.events as ev}
          <div class="flex items-center gap-3 px-4 py-2 text-[12.5px]">
            <span class="text-dim/60 text-[11px] w-[64px] shrink-0">{ago(ev.at)}</span>
            <Pill label={ev.scope || ev.kind || 'event'} color="var(--color-dim)" />
            <span class="flex-1 truncate">{ev.title || ev.kind}</span>
            <span class="text-dim/60 text-[11px] font-mono truncate max-w-[14ch]">{ev.actor || ''}</span>
          </div>
        {:else}<div class="px-4 py-8 text-center text-dim/70 text-[13px]">No activity yet.</div>{/each}
      </div>
    {:else if page === 'profile'}
      <div class="rounded-2xl border border-line bg-card p-5 mb-4">
        <div class="text-[13px] mb-4"><span class="font-medium">{data.me?.email || '—'}</span><span class="text-dim"> · your role </span><Pill label={data.me?.role || 'viewer'} color={roleColor(data.me?.role)} /></div>
        <div class="grid grid-cols-2 gap-3">
          {#each [['display', 'Display name'], ['tagline', 'Tagline'], ['location', 'Location'], ['links', 'Links']] as [k, lbl]}
            <label class="text-[12px] text-dim">{lbl}<input bind:value={pform[k]} class="mt-1 w-full bg-paper border border-line rounded-lg px-3 py-2 text-[13px] text-ink outline-none focus:border-ink" /></label>
          {/each}
        </div>
        <button onclick={doSaveProfile} class="mt-4 px-3.5 py-2 rounded-xl text-[13px] font-medium" style="background:var(--color-ink);color:var(--color-paper)">Save</button>
      </div>
      <div class="text-[11px] text-dim/60">Org display-name + ownership transfer land with the next runtime release.</div>
    {:else if page === 'security'}
      <div class="text-[10px] font-mono uppercase tracking-wider text-dim/60 mb-1.5">Device keys</div>
      <div class="rounded-2xl border border-line bg-card divide-y divide-line">
        {#each data.keys as k}
          <div class="group flex items-center gap-3 px-4 py-2.5 text-[13px]"><span class="flex-1 truncate font-mono">{k.name || k.id}</span><span class="text-dim/60 text-[11px]">added {ago(k.created_at)}</span><button onclick={() => doRevokeKey(k)} title="Revoke" class="opacity-0 group-hover:opacity-100 text-dim hover:text-[var(--color-bad)] [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('trash', 14)}</button></div>
        {:else}<div class="px-4 py-8 text-center text-dim/70 text-[13px]">No device keys registered.</div>{/each}
      </div>
      <div class="text-[11px] text-dim/60 mt-3">Active-session listing + "sign out everywhere" land with the next runtime release.</div>
    {:else if page === 'visibility'}
      <div class="rounded-2xl border border-line bg-card divide-y divide-line">
        {#each data.workspaces.filter((w) => w.id !== 'admin') as w}
          <div class="flex items-center gap-3 px-4 py-2.5 text-[13px]"><span class="flex-1 truncate">{w.name || w.id}</span>
            <div class="flex rounded-lg border border-line overflow-hidden text-[11px]">{#each VIS as v}<button onclick={() => doSetVisibility(w, v)} class="px-2 py-1 {(w.visibility || 'public') === v ? 'text-ink bg-card' : 'text-dim hover:text-ink'}">{v}</button>{/each}</div>
          </div>
        {/each}
      </div>
    {:else if page === 'integrations'}
      <div class="rounded-2xl border border-line bg-card p-5">
        <div class="flex items-center gap-2.5 mb-2"><span class="[&>svg]:w-[17px] [&>svg]:h-[17px] text-ink">{@html iconSvgByName('git-fork', 17)}</span><span class="font-medium text-[14px]">GitHub</span><Pill label={data.github?.configured ? 'connected' : 'not set up'} color={data.github?.configured ? 'var(--color-mint)' : 'var(--color-dim)'} /></div>
        <div class="text-[12.5px] text-dim">{(data.github?.installations || []).length} installation(s){#if data.github?.webhook_secret} · webhooks active{/if}</div>
      </div>
    {:else if page === 'schedules'}
      <div class="rounded-2xl border border-line bg-card divide-y divide-line">
        {#each data.schedules as sc}
          <div class="group flex items-center gap-3 px-4 py-2.5 text-[13px]"><span class="flex-1 truncate">{sc.title || sc.id}</span><span class="text-dim/60 text-[11px] font-mono">{sc.cron || sc.every || ''}</span><button onclick={() => doCancelSchedule(sc)} class="opacity-0 group-hover:opacity-100 text-[11px] px-2 py-0.5 rounded-md border border-line text-dim hover:text-[var(--color-bad)]">Cancel</button></div>
        {:else}<div class="px-4 py-8 text-center text-dim/70 text-[13px]">No scheduled automation.</div>{/each}
      </div>
    {:else if page === 'danger'}
      <div class="rounded-2xl border p-5" style="border-color:color-mix(in srgb,var(--color-bad) 35%,var(--color-line))">
        <div class="text-[10px] font-mono uppercase tracking-wider mb-2.5" style="color:var(--color-bad)">Delete a workspace</div>
        <div class="divide-y divide-line">
          {#each data.workspaces.filter((w) => w.id !== 'admin') as w}
            <div class="flex items-center gap-3 py-2 text-[13px]"><span class="flex-1 truncate">{w.name || w.id}</span><button onclick={() => doDeleteWorkspace(w)} class="text-[11px] px-2.5 py-1 rounded-md border" style="color:var(--color-bad);border-color:color-mix(in srgb,var(--color-bad) 40%,transparent)">Delete</button></div>
          {/each}
        </div>
        <div class="text-[11px] text-dim/60 mt-4">Leave org · transfer ownership · delete org · data export land with the next runtime release.</div>
      </div>
    {/if}
  </div>
</div>
