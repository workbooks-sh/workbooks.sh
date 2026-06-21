WB.scopedStyles('/storage', ``);

WB.view('/storage', {
  title: 'Storage',
  accent: 'var(--sky)',
  async render(el, ctx) {
    const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    // Paint-first (the load-time rule): the page shell + a skeleton render IMMEDIATELY, then the data
    // fetch fills it in — no blank screen blocking on the API.
    el.innerHTML = `
<section>
  <div class="sechead">
    <div>
      <h2>Storage</h2>
      <p>Object storage for your nexus — images &amp; files, served with zero egress.</p>
    </div>
    <div class="dim mono" style="font-size:13px" id="sttotal">…</div>
  </div>
  <div id="stbody"><div class="card faint" style="text-align:center;color:var(--dim)">Loading storage…</div></div>
  <div class="note">Storage lives outside the nexus container — it survives sleep/restart and never bloats the runtime image. Egress is $0 because blobs are served directly, so reads are free.</div>
</section>`;

    // Stale-while-revalidate: paint cached data instantly, refresh in the background.
    await WB.swr('storage', () => WB.api.listBuckets(), (data) => {
      data = data || {};
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

      const slot = el.querySelector('#stbody'); if (slot) slot.innerHTML = body;
      const tot = el.querySelector('#sttotal'); if (tot) tot.textContent = totalSize + ' total';
    });
  }
});
