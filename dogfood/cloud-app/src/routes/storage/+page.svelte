<script>
  let { data } = $props();

  // Real per-org storage: one bucket per nexus, plus the org total (from the runtime).
  const buckets = $derived(data.buckets || []);
  const totalSize = $derived(data.totalSize || '0 GB');
</script>

<section>
  <div class="sechead">
    <div>
      <h2>Storage</h2>
      <p>Object storage for your nexus — images &amp; files, served with zero egress.</p>
    </div>
    <div class="dim mono" style="font-size:13px">{totalSize} total</div>
  </div>

  {#if buckets.length === 0}
    <div class="card faint" style="text-align:center;color:var(--dim)">
      No storage yet. Your nexus gets a bucket — create your nexus to get started.
    </div>
  {:else}
    <div class="card" style="padding:0;overflow:hidden">
      <table>
        <thead>
          <tr><th>Bucket</th><th>Attached to</th><th class="num">Objects</th><th class="num">Size</th><th class="num">Egress</th></tr>
        </thead>
        <tbody>
          {#each buckets as b (b.name)}
            <tr>
              <td class="mono">{b.name}</td>
              <td class="dim">{b.nexus}</td>
              <td class="num">{b.objects == null ? '—' : b.objects.toLocaleString()}</td>
              <td class="num">{b.size}</td>
              <td class="num" style="color:var(--run)">{b.egress}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}

  <div class="note">Storage lives outside the nexus container — it survives sleep/restart and never bloats the runtime image. Egress is $0 because blobs are served directly, so reads are free.</div>
</section>
