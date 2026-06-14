<script>
  let { data } = $props();
</script>

<section>
  <div class="sechead">
    <div>
      <h2>Storage</h2>
      <p>Object storage for your nexuses — images &amp; files. Served zero-egress via Cloudflare R2.</p>
    </div>
    <button class="btn sm">New bucket</button>
  </div>

  <div class="card" style="padding:0;overflow:hidden">
    <table>
      <thead>
        <tr><th>Bucket</th><th>Attached to</th><th class="num">Objects</th><th class="num">Size</th><th class="num">Egress</th></tr>
      </thead>
      <tbody>
        {#each data.buckets as b (b.name)}
          <tr>
            <td class="mono">{b.name}</td>
            <td class="dim">{b.nexus}</td>
            <td class="num">{b.objects.toLocaleString()}</td>
            <td class="num">{b.size}</td>
            <td class="num" style="color:var(--run)">{b.egress}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>

  <div class="note">Storage lives outside the nexus container — it survives sleep/restart and never bloats the runtime image. Egress is $0 because blobs are served from R2, not the compute host.</div>
</section>
