<script>
  // The UPGRADE interface — the canonical upsell surface. One nexus per org, scaled
  // by stage. No "create another nexus": you move your one nexus up a stage. The only
  // dials are memory + bandwidth; workspaces and users are unlimited.
  //
  // The hero is MARKETING LOGIC: an AI in the nexus assembles personalized copy for
  // this org (prices stay pinned — see Nexus.Upsell / templates/marketing). The tier
  // ladder below is the full, static comparison.
  import { getUpsell } from '$lib/api.js';
  import { onMount } from 'svelte';

  let { data } = $props();
  const ladder = $derived(data.ladder);
  const currentTier = $derived(data.currentTier);
  const currentIdx = $derived(ladder.findIndex((t) => t.id === currentTier));
  const orgName = $derived(data?.profile?.orgName || '');

  let page = $state(null);     // the AI-assembled page model
  let busy = $state(false);
  async function personalize() {
    busy = true;
    try { page = await getUpsell(orgName); } catch { page = null; }
    busy = false;
  }
  const heroBlock = $derived(page?.blocks?.find((b) => b.type === 'hero'));
  const ctaBlock = $derived(page?.blocks?.find((b) => b.type === 'cta'));
  onMount(personalize);
</script>

<section>
  <div class="sechead">
    <div><h2>Scale your nexus</h2><p>One nexus, scaled to fit. No per-seat billing — you pay for memory and bandwidth, never for people.</p></div>
  </div>

  {#if heroBlock}
    <div class="hero" class:ai={page?.personalized}>
      <h1>{heroBlock.copy.headline}</h1>
      {#if heroBlock.copy.subhead}<p>{heroBlock.copy.subhead}</p>{/if}
      {#if ctaBlock && !page?.at_ceiling}
        <div class="hero-cta">
          <a class="btn sm primary" href={ctaBlock.href}>{ctaBlock.copy.label}</a>
          <span class="dim">{ctaBlock.copy.sub}</span>
        </div>
      {/if}
      <button class="repersonalize" onclick={personalize} disabled={busy} title="Re-assemble for {orgName || 'your org'}">
        {busy ? 'Personalizing…' : page?.personalized ? `✦ Personalized for ${page.org} by your nexus` : 'Personalize this page'}
      </button>
    </div>
  {/if}

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
</style>
