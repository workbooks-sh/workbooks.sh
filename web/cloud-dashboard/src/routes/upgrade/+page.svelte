<script>
  // The UPGRADE interface — the canonical upsell surface. One nexus per org, scaled
  // by stage. No "create another nexus": you move your one nexus up a stage. The only
  // dials are memory + bandwidth; workspaces and users are unlimited. Simple for now —
  // the richer per-stage marketing pages grow from this same upsells source.
  let { data } = $props();
  const ladder = $derived(data.ladder);
  const currentTier = $derived(data.currentTier);
  const currentIdx = $derived(ladder.findIndex((t) => t.id === currentTier));
</script>

<section>
  <div class="sechead">
    <div><h2>Scale your nexus</h2><p>One nexus, scaled to fit. No per-seat billing — you pay for memory and bandwidth, never for people.</p></div>
  </div>

  <div class="ladder">
    {#each ladder as t, i}
      {@const current = t.id === currentTier}
      {@const below = i < currentIdx}
      <div class="tier" class:current class:featured={i === currentIdx + 1}>
        <div class="thead">
          <span class="tag">{t.tag}</span>
          {#if current}<span class="badge">Current plan</span>{:else if t.domains}<span class="badge dim">Custom domains</span>{/if}
        </div>
        <div class="name">{t.name}</div>
        <div class="price">{t.priceLabel}</div>
        <p class="pitch">{t.pitch}</p>

        <div class="dials">
          <div class="d"><span class="dk">Memory</span><span class="dv">{t.memory} RAM</span></div>
          <div class="d"><span class="dk">Bandwidth & storage</span><span class="dv">{t.bandwidth}</span></div>
        </div>

        <ul class="feat">
          {#each t.unlimited as f}<li>{f}</li>{/each}
        </ul>

        {#if t.unlocks.length && !below && !current}
          <div class="unlocks">
            <span class="ul-h">Unlocks</span>
            {#each t.unlocks as u}<div class="ul">↑ {u}</div>{/each}
          </div>
        {/if}

        <div class="cta">
          {#if current}
            <button class="btn sm" disabled>You're on {t.name}</button>
          {:else if below}
            <span class="dim" style="font-size:12px">Included below your plan</span>
          {:else}
            <a class="btn sm primary" href="/billing/checkout?plan={t.id}">Scale to {t.name}</a>
          {/if}
        </div>
      </div>
    {/each}
  </div>

  <p class="foot-note">Every plan includes unlimited workspaces and users — organize your work however you like. Need a hard separation? That's a new organization, not another nexus. Billing runs through Polar (sandbox while we finish setup).</p>
</section>

<style>
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
</style>
