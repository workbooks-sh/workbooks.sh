<script>
  import { toast } from '$lib/toastStore.svelte.js';
  let { data } = $props();
  const u = $derived(data.usage);
  const s = $derived(u.summary);
</script>

<section>
  <div class="sechead">
    <div><h2>Usage &amp; billing</h2><p>{u.period}</p></div>
    <button class="btn sm" onclick={() => toast('Invoice downloading…')}>Download invoice</button>
  </div>

  <div class="stats">
    <div class="stat"><div class="k">Month to date</div><div class="v">${s.monthToDate}</div><div class="d dim">{s.nexusCount} nexuses</div></div>
    <div class="stat"><div class="k">Compute</div><div class="v">${s.compute}</div><div class="d dim">{s.activeHrs} active hrs</div></div>
    <div class="stat"><div class="k">Storage</div><div class="v">${s.storage}</div><div class="d dim">R2 · zero egress</div></div>
    <div class="stat"><div class="k">Database</div><div class="v">${s.database}</div><div class="d dim">1 Postgres addon</div></div>
  </div>

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

  <div class="card">
    <h3>Plan</h3>
    <div class="kv"><span class="k">Tier</span><span class="v">Pay-as-you-grow · entry from $20/mo</span></div>
    <div class="kv"><span class="k">Pricing model</span><span class="v">flat base + metered active compute</span></div>
    <div class="note">Idle nexuses scale to zero, so you're billed for active compute, storage, and any database addon — not for sitting still. Additional nexuses are discounted against your base.</div>
  </div>
</section>
