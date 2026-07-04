WB.scopedStyles('/upgrade', `
  .hero { background:var(--card); border:1.5px solid var(--line); border-radius:18px; padding:28px 26px; margin-bottom:18px; }
  .hero.ai { border-color:var(--ink); box-shadow:0 8px 30px -16px color-mix(in srgb, var(--ink) 45%, transparent); }
  .hero h1 { font:700 26px var(--read); letter-spacing:-.02em; color:var(--ink); margin:0 0 6px; }
  .hero p { font-size:15px; color:var(--dim); margin:0; }
  .hero-cta { display:flex; align-items:center; gap:12px; margin-top:16px; }
  .repersonalize { margin-top:14px; background:none; border:0; padding:0; cursor:pointer; font:600 12px var(--mono); letter-spacing:.03em; color:var(--dim); }
  .repersonalize:hover { color:var(--ink); }
  .ladder { display:grid; grid-template-columns:repeat(auto-fit, minmax(240px, 1fr)); gap:14px; }
  .tier { background:var(--card); border:1.5px solid var(--line); border-radius:16px; padding:20px; display:flex; flex-direction:column; }
  .tier.current { border-color:var(--live); }
  .tier.featured { border-color:var(--ink); box-shadow:0 6px 24px -12px color-mix(in srgb, var(--ink) 40%, transparent); }
  .thead { display:flex; align-items:center; justify-content:space-between; min-height:22px; }
  .tag { font:700 10px var(--mono); letter-spacing:.08em; text-transform:uppercase; color:var(--dim); }
  .badge { font:600 10px var(--mono); letter-spacing:.05em; text-transform:uppercase; padding:3px 8px; border-radius:6px; border:1.5px solid var(--live); color:var(--live); }
  .badge.dim { border-color:var(--line); color:var(--dim); }
  .name { font:700 22px var(--read); color:var(--ink); margin:10px 0 2px; letter-spacing:-.02em; }
  .price { font:700 18px var(--read); color:var(--ink); }
  .pitch { font-size:13px; color:var(--dim); margin:8px 0 14px; min-height:36px; }
  .dials { border-top:1px solid var(--line-soft); border-bottom:1px solid var(--line-soft); padding:10px 0; margin-bottom:12px; }
  .d { display:flex; align-items:baseline; justify-content:space-between; padding:3px 0; }
  .dk { font-size:12px; color:var(--dim); }
  .dv { font:600 13px var(--mono); color:var(--ink); }
  .feat { list-style:none; padding:0; margin:0 0 12px; }
  .feat li { font-size:12.5px; color:var(--ink); padding:3px 0 3px 18px; position:relative; }
  .feat li::before { content:'✓'; position:absolute; left:0; color:var(--live); font-weight:700; }
  .unlocks { background:color-mix(in srgb, var(--ink) 5%, transparent); border-radius:10px; padding:10px 12px; margin-bottom:12px; }
  .ul-h { font:700 10px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); display:block; margin-bottom:4px; }
  .ul { font-size:12.5px; color:var(--ink); padding:2px 0; }
  .cta { margin-top:auto; }
  .cta .btn { width:100%; }
  .foot-note { font-size:12.5px; color:var(--dim); margin-top:16px; text-align:center; }
`);

WB.view('/upgrade', {
  title: 'Scale your nexus',
  accent: 'var(--mint)',
  async render(el, ctx) {
    const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    // ── upsells() helper (inlined from $lib/upsells.js) ──
    const STAGE = {
      starter: { tag: 'Start', headline: 'Free to start', pitch: 'Everything to build and ship your first workbooks — free.' },
      team: { tag: 'Grow', headline: 'For growing teams', pitch: 'More memory and bandwidth, plus your own custom domain.' },
      scale: { tag: 'Scale', headline: 'For scale', pitch: 'Serious memory and bandwidth for heavy, always-on workloads.' }
    };
    const UNLOCKS = {
      team: ['4× the memory', '10× the bandwidth & storage', 'Custom domains', 'Priority support'],
      scale: ['4× more memory again', '10× more bandwidth & storage', 'Dedicated capacity']
    };
    const FALLBACK = [
      { id: 'starter', name: 'Starter', ram_mb: 1024, storage_gb: 10, price: 0, 'domains?': false },
      { id: 'team', name: 'Team', ram_mb: 4096, storage_gb: 100, price: 49, 'domains?': true },
      { id: 'scale', name: 'Scale', ram_mb: 16384, storage_gb: 1000, price: 199, 'domains?': true }
    ];
    const ram = (mb) => (mb >= 1024 ? `${mb / 1024} GB` : `${mb} MB`);
    async function upsells() {
      let tiers = [];
      try { tiers = await WB.api.listTiers(); } catch {}
      if (!tiers.length) tiers = FALLBACK;
      return tiers.map((t) => ({
        id: t.id,
        name: t.name,
        ...STAGE[t.id],
        price: t.price,
        priceLabel: t.price ? `$${t.price}/mo` : 'Free',
        memory: ram(t.ram_mb),
        bandwidth: `${t.storage_gb} GB`,
        domains: t['domains?'] ?? t.domains ?? false,
        unlocks: UNLOCKS[t.id] || [],
        unlimited: ['Unlimited workspaces', 'Unlimited users', 'Zero-egress storage', 'Postgres included']
      }));
    }

    // ── loader (from +page.js) ──
    const [ladder, usage] = await Promise.all([upsells(), WB.api.nexusUsage()]);
    const currentTier = usage?.capacity?.tier?.id || 'starter';
    const profile = WB.profile || {};
    const data = { ladder, currentTier, profile };

    const currentIdx = ladder.findIndex((t) => t.id === currentTier);
    const orgName = data?.profile?.orgName || '';

    // ── personalize state ──
    let page = null;
    let busy = false;

    function heroBlockOf(p) { return p?.blocks?.find((b) => b.type === 'hero'); }
    function ctaBlockOf(p) { return p?.blocks?.find((b) => b.type === 'cta'); }

    async function personalize() {
      busy = true; paint();
      try { page = await WB.api.getUpsell(orgName); } catch { page = null; }
      busy = false; paint();
    }

    function paint() {
      const heroBlock = heroBlockOf(page);
      const ctaBlock = ctaBlockOf(page);

      let heroHtml = '';
      if (heroBlock) {
        const repersLabel = busy
          ? 'Personalizing…'
          : page?.personalized
            ? `✦ Personalized for ${esc(page.org)} by your nexus`
            : 'Personalize this page';
        const ctaHtml = (ctaBlock && !page?.at_ceiling) ? `
        <div class="hero-cta">
          <a class="btn sm primary" href="${esc(ctaBlock.href)}">${esc(ctaBlock.copy.label)}</a>
          <span class="dim">${esc(ctaBlock.copy.sub)}</span>
        </div>` : '';
        heroHtml = `
    <div class="hero${page?.personalized ? ' ai' : ''}">
      <h1>${esc(heroBlock.copy.headline)}</h1>
      ${heroBlock.copy.subhead ? `<p>${esc(heroBlock.copy.subhead)}</p>` : ''}
      ${ctaHtml}
      <button class="repersonalize"${busy ? ' disabled' : ''} title="Re-assemble for ${esc(orgName || 'your org')}">
        ${repersLabel}
      </button>
    </div>`;
      }

      const tiersHtml = ladder.map((t, i) => {
        const current = t.id === currentTier;
        const below = i < currentIdx;
        const cls = `tier${current ? ' current' : ''}${i === currentIdx + 1 ? ' featured' : ''}`;
        const headBadge = current
          ? `<span class="badge">Current plan</span>`
          : (t.domains ? `<span class="badge dim">Custom domains</span>` : '');
        const feat = t.unlimited.map((f) => `<li>${esc(f)}</li>`).join('');
        const unlocks = (t.unlocks.length && !below && !current) ? `
          <div class="unlocks">
            <span class="ul-h">Unlocks</span>
            ${t.unlocks.map((u) => `<div class="ul">↑ ${esc(u)}</div>`).join('')}
          </div>` : '';
        let cta;
        if (current) cta = `<button class="btn sm" disabled>You're on ${esc(t.name)}</button>`;
        else if (below) cta = `<span class="dim" style="font-size:12px">Included below your plan</span>`;
        else cta = `<button class="btn sm primary" data-checkout="${esc(t.id)}">Scale to ${esc(t.name)}</button>`;
        return `
      <div class="${cls}">
        <div class="thead">
          <span class="tag">${esc(t.tag)}</span>
          ${headBadge}
        </div>
        <div class="name">${esc(t.name)}</div>
        <div class="price">${esc(t.priceLabel)}</div>
        <p class="pitch">${esc(t.pitch)}</p>

        <div class="dials">
          <div class="d"><span class="dk">Memory</span><span class="dv">${esc(t.memory)} RAM</span></div>
          <div class="d"><span class="dk">Bandwidth & storage</span><span class="dv">${esc(t.bandwidth)}</span></div>
        </div>

        <ul class="feat">
          ${feat}
        </ul>

        ${unlocks}

        <div class="cta">
          ${cta}
        </div>
      </div>`;
      }).join('');

      el.innerHTML = `
<section>
  <div class="sechead">
    <div><h2>Scale your nexus</h2><p>One nexus, scaled to fit. No per-seat billing — you pay for memory and bandwidth, never for people.</p></div>
  </div>

  ${heroHtml}

  <div class="ladder">
    ${tiersHtml}
  </div>

  <p class="foot-note">Every plan includes unlimited workspaces and users — organize your work however you like. Need a hard separation? That's a new organization, not another nexus. Billing runs through Polar (sandbox while we finish setup).</p>
</section>`;

      const rebtn = el.querySelector('.repersonalize');
      if (rebtn) rebtn.onclick = personalize;

      // Subscription upgrade → Polar checkout (card on file reused; external_customer_id = org server-side).
      el.querySelectorAll('[data-checkout]').forEach((b) => { b.onclick = () => startCheckout(b); });
    }

    async function startCheckout(btn) {
      const tier = btn.getAttribute('data-checkout');
      const label = btn.textContent;
      btn.disabled = true; btn.textContent = 'Starting checkout…';
      try {
        const r = await fetch('/cloud/billing/checkout', {
          method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ tier, success_url: location.origin + '/cloud/' })
        }).then((x) => x.json());
        if (r && r.url) { location.href = r.url; return; }
        (WB.toast || alert)((r && (r.message || r.error)) || 'Could not start checkout.');
      } catch (e) { (WB.toast || alert)('Could not start checkout.'); }
      btn.disabled = false; btn.textContent = label;
    }

    paint();
    // onMount
    personalize();
  }
});
