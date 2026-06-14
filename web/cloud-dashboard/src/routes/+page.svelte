<script>
  import { STATE_LABEL } from '$lib/api.js';
  import Sparkline from '$lib/Sparkline.svelte';
  import { nexusStore } from '$lib/nexusStore.svelte.js';

  const rows = $derived(nexusStore.filtered);
</script>

<section>
  <div class="sechead">
    <div>
      <h2>Nexuses</h2>
      <p>Your hosted runtimes. Idle ones sleep automatically — you only pay while they work.</p>
    </div>
  </div>

  <div>
    {#each rows as n, i (n.id)}
      <a class="row" href="/nexuses/{n.id}">
        <div class="nx">
          <b><span class="dot {n.state}"></span>{n.name}</b>
          <div class="url">{n.url}</div>
        </div>
        {#if n.state === 'run'}
          <Sparkline seed={i + 1} />
        {:else}
          <div class="spark"></div>
        {/if}
        <div class="tag">{n.region}</div>
        <div class="meta">
          <div class="st">{STATE_LABEL[n.state]}</div>
          <div class="sub">{n.plan.split(' · ')[1] || n.plan}</div>
        </div>
      </a>
    {/each}
    {#if rows.length === 0}
      <div class="card" style="text-align:center;color:var(--dim)">
        No nexuses match “{nexusStore.query}”.
      </div>
    {/if}
  </div>
</section>
