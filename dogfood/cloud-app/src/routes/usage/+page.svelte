<script>
  import { toast } from '$lib/toastStore.svelte.js';
  let { data } = $props();
  const u = $derived(data.usage);
  const s = $derived(u.summary);
  const cap = $derived(u.capacity);   // {tier, next, ram, storage, topRam, topObjects}
  const hot = $derived(cap && (cap.ram.status !== 'ok' || cap.storage.status !== 'ok'));
</script>

<section>
  <div class="sechead">
    <div><h2>Usage &amp; billing</h2><p>{u.period}</p></div>
    <button class="btn sm" onclick={() => toast('Invoice downloading…')}>Download invoice</button>
  </div>

  <div class="stats">
    <div class="stat"><div class="k">Month to date</div><div class="v">{s.monthToDate}</div><div class="d dim">{s.nexusCount} nexuses</div></div>
    <div class="stat"><div class="k">Compute</div><div class="v">{s.compute}</div><div class="d dim">{s.activeHrs} active hrs</div></div>
    <div class="stat"><div class="k">Storage</div><div class="v">{s.storage}</div><div class="d dim">zero egress</div></div>
    <div class="stat"><div class="k">Database</div><div class="v">{s.database}</div><div class="d dim">managed Postgres</div></div>
  </div>

  {#if u.rows.length === 0}
    <div class="card faint" style="text-align:center;color:var(--dim)">
      No usage yet. Costs accrue as your nexuses run — idle time is free.
    </div>
  {:else}
    <div class="card" style="padding:0;overflow:hidden">
      <table>
        <thead><tr><th>Nexus</th><th>Plan</th><th class="num">Active hrs</th><th class="num">Storage</th><th class="num">Database</th><th class="num">Cost</th></tr></thead>
        <tbody>
          {#each u.rows as r}
            <tr>
              <td><b>{r.name}</b></td>
              <td class="dim">{r.plan}</td>
              <td class="num">{r.activeHrs}</td>
              <td class="num">{r.storage}</td>
              <td class="num" class:faint={r.database === '—'}>{r.database}</td>
              <td class="num" style="color:var(--live)">{r.cost}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}

  {#if cap}
    <div class="card">
      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:12px">
        <h3>Capacity — {cap.tier.name} plan</h3>
        <span class="dim" style="font-size:12.5px">auto-scales within your tier · {cap.tier.ram_mb} MB · {cap.tier.storage_gb} GB</span>
      </div>

      {#each [cap.ram, cap.storage] as d, i}
        <div class="dial">
          <div class="dial-top"><span class="dl">{i === 0 ? 'RAM' : 'Storage'}</span><span class="dv" class:near={d.status === 'near'} class:over={d.status === 'over'}>{d.label}</span></div>
          <div class="bar"><div class="fill" class:near={d.status === 'near'} class:over={d.status === 'over'} style="width:{Math.max(2, d.pct)}%"></div></div>
        </div>
      {/each}

      {#if hot}
        <div class="hot">
          <p><b>Near capacity.</b> You're auto-scaling against your {cap.tier.name} ceiling.
            {#if cap.next}Move to <b>{cap.next.name}</b> ({cap.next.ram_mb} MB · {cap.next.storage_gb} GB · {cap.next.price}/mo) to keep growing{:else}You're on the top tier — split into a new organization for more headroom{/if}.</p>
          {#if cap.next}<a class="btn sm primary" href="/upgrade">Scale to {cap.next.name}</a>{/if}
        </div>
        {#if cap.topRam.length}
          <div class="shed"><span class="sh">Top RAM</span>
            {#each cap.topRam.slice(0, 4) as r}<div class="srow2"><span class="dim">{r.name}</span><span class="mono">{r.label}</span></div>{/each}
          </div>
        {/if}
        {#if cap.topObjects.length}
          <div class="shed"><span class="sh">Biggest objects</span>
            {#each cap.topObjects.slice(0, 4) as o}<div class="srow2"><span class="mono dim">{o.key}</span><span class="mono">{o.label}</span></div>{/each}
          </div>
        {/if}
      {:else}
        <p class="note">Healthy — plenty of headroom. We scale you up automatically as you grow, up to your tier ceiling.</p>
      {/if}
    </div>
  {/if}

  <div class="card">
    <h3>Plan</h3>
    <div class="kv"><span class="k">Pricing</span><span class="v">No seat billing · unlimited users</span></div>
    <div class="kv"><span class="k">Model</span><span class="v">storage-gated tiers + metered active compute</span></div>
    <div class="note">Idle nexuses scale to zero, so you're billed for active compute, storage, and any database addon — not for sitting still, and never per seat.</div>
  </div>
</section>

<style>
  .dial { padding:10px 0; border-bottom:1px solid var(--line-soft); }
  .dial:last-of-type { border:0; }
  .dial-top { display:flex; align-items:baseline; justify-content:space-between; margin-bottom:6px; }
  .dl { font:600 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
  .dv { font:600 13px var(--mono); color:var(--ink); }
  .dv.near { color:var(--peach-ink, #9a6a3a); }
  .dv.over { color:#c0392b; }
  .bar { height:8px; border-radius:6px; background:var(--line-soft); overflow:hidden; }
  .fill { height:100%; border-radius:6px; background:var(--live); transition:width .4s ease; }
  .fill.near { background:var(--peach, #f3c5a3); }
  .fill.over { background:#e07a5f; }
  .hot { margin-top:12px; padding:12px 14px; border:1.5px solid var(--peach, #f3c5a3); border-radius:10px; background:color-mix(in srgb, var(--peach, #f3c5a3) 14%, transparent); }
  .hot p { font-size:13px; margin:0 0 8px; }
  .shed { margin-top:10px; }
  .sh { display:block; font:600 10px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); margin-bottom:4px; }
  .srow2 { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:3px 0; font-size:12.5px; }
  .srow2 .mono { font-size:12px; }
</style>
