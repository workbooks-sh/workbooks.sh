<script>
  import { nexusStore } from '$lib/nexusStore.svelte.js';
  const nx = $derived(nexusStore.active);
</script>

<section>
  <div class="sechead">
    <div>
      <h2>Database</h2>
      <p>A managed Postgres database, included with your nexus. It scales down with the nexus, so it costs nothing while idle.</p>
    </div>
  </div>

  <div class="card">
    <h3>Connection</h3>
    <div class="kv"><span class="k">Status</span><span class="v" style="color:var(--live)">Included</span></div>
    <div class="kv"><span class="k">Engine</span><span class="v">Postgres</span></div>
    <div class="kv"><span class="k">Nexus</span><span class="v">{nx?.name || '—'}</span></div>
    <div class="note">Connection details and managed-Postgres provisioning land here once your database is wired — your workbooks reach it from inside the nexus.</div>
  </div>
</section>
