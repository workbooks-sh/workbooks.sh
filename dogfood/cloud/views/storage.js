WB.scopedStyles('/storage', ``);

WB.view('/storage', {
  title: 'Storage',
  accent: 'var(--sky)',
  async render(el, ctx) {
    const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    // +page.js loader: return await listBuckets()
    const data = await WB.api.listBuckets();
    const buckets = data.buckets || [];
    const totalSize = data.totalSize || '0 GB';

    let body;
    if (buckets.length === 0) {
      body = `
    <div class="card faint" style="text-align:center;color:var(--dim)">
      No storage yet. Your nexus gets a bucket — create your nexus to get started.
    </div>`;
    } else {
      body = `
    <div class="card" style="padding:0;overflow:hidden">
      <table>
        <thead>
          <tr><th>Bucket</th><th>Attached to</th><th class="num">Objects</th><th class="num">Size</th><th class="num">Egress</th></tr>
        </thead>
        <tbody>
          ${buckets.map((b) => `
            <tr>
              <td class="mono">${esc(b.name)}</td>
              <td class="dim">${esc(b.nexus)}</td>
              <td class="num">${b.objects == null ? '—' : esc(b.objects.toLocaleString())}</td>
              <td class="num">${esc(b.size)}</td>
              <td class="num" style="color:var(--run)">${esc(b.egress)}</td>
            </tr>`).join('')}
        </tbody>
      </table>
    </div>`;
    }

    el.innerHTML = `
<section>
  <div class="sechead">
    <div>
      <h2>Storage</h2>
      <p>Object storage for your nexus — images &amp; files, served with zero egress.</p>
    </div>
    <div class="dim mono" style="font-size:13px">${esc(totalSize)} total</div>
  </div>
  ${body}
  <div class="note">Storage lives outside the nexus container — it survives sleep/restart and never bloats the runtime image. Egress is $0 because blobs are served directly, so reads are free.</div>
</section>`;
  }
});
