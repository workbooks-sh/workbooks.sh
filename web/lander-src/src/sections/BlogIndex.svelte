<script>
  // The blog index, rendered IN-SHELL. Reuses the same /content/blog.json
  // manifest the runtime CMS publishes (the on-page listing reads it too); a
  // fuller list is fine here. Each entry links to /blog/<slug>; the shell's
  // global click interception turns that into an in-shell push (no document
  // reload), so the cursor / panel / follow session never tear down.
  let posts = $state(null);   // null = loading, [] = none/failed
  $effect(() => {
    let alive = true;
    (async () => {
      try {
        const res = await fetch('/content/blog.json', { signal: AbortSignal.timeout(8000) });
        const data = res.ok ? await res.json() : null;
        // accept either a bare array or { posts: [...] } — be liberal in shape
        const list = Array.isArray(data) ? data : (data && data.posts) || [];
        if (alive) posts = list;
      } catch { if (alive) posts = []; }
    })();
    return () => { alive = false; };
  });

  const fmtDate = (d) => {
    if (!d) return '';
    const t = new Date(d);
    return isNaN(t) ? d : t.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  };
</script>

<section class="band">
 <div class="inner">
  <div class="kicker">writing</div>
  <h2>The blog</h2>
  <p class="lede">Notes from Waldo and the team — shipped to this same page, read
  without ever leaving it.</p>

  {#if posts === null}
    <p class="lede">loading…</p>
  {:else if posts.length === 0}
    <p class="lede">No posts yet.</p>
  {:else}
    <div class="postgrid">
      {#each posts as p (p.slug)}
        <a class="postcard" href={`/blog/${p.slug}`}>
          <span class="pc-meta">
            {#if p.tag}<span class="pc-tag">{p.tag}</span>{/if}
            {#if p.date}<span class="pc-date">{fmtDate(p.date)}</span>{/if}
          </span>
          <span class="pc-title">{p.title || p.slug}</span>
          {#if p.excerpt}<span class="pc-excerpt">{p.excerpt}</span>{/if}
          <span class="pc-read">read →</span>
        </a>
      {/each}
    </div>
  {/if}
 </div>
</section>
