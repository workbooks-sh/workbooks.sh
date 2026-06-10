<script>
  // A blog post, rendered IN-SHELL. The live posts are standalone HTML at
  // /blog/<slug>.html with their own <head>/<style>/nav and a `<div class="wrap">…</div>`
  // body. We fetch that document, parse it with DOMParser, and pull ONLY the
  // article body into #route — never the post's own <head>, nav, or site.js (the
  // shell already provides all of those; injecting them would double the nav and
  // boot the compact panel that this whole change exists to eliminate). The
  // post's inline <style> is the one thing we keep + inline, since the standalone
  // page relied on it for typography; it's scoped under .blogpost defensively.
  let { slug } = $props();
  let html = $state(null);    // null = loading, '' = failed/404
  let host = $state(null);

  $effect(() => {
    let alive = true;
    html = null;
    (async () => {
      try {
        const res = await fetch(`/blog/${slug}.html`, { signal: AbortSignal.timeout(9000) });
        if (!res.ok) { if (alive) html = ''; return; }
        const doc = new DOMParser().parseFromString(await res.text(), 'text/html');
        // the article body: .wrap inner if present, else <body> minus the
        // injected nav/panel/script chrome that the shell already supplies.
        let body = doc.querySelector('.wrap');
        if (!body) body = doc.body;
        // the shell supplies the chrome AND the "← blog" breadcrumb, so strip
        // the post's own nav/script/panel AND its top back-link (.topnote) —
        // otherwise the page shows two stacked breadcrumbs.
        body.querySelectorAll('nav, script, .wbp, .wbpeek, #timeline, .topnote').forEach((n) => n.remove());
        // keep the post's own typography <style> (inlined into the node so it
        // travels with the content and is removed when we navigate away).
        const styles = [...doc.querySelectorAll('style')].map((s) => s.textContent).join('\n');
        const inner = body.innerHTML;
        if (alive) html = (styles ? `<style>${styles}</style>` : '') + inner;
      } catch { if (alive) html = ''; }
    })();
    return () => { alive = false; };
  });

  // inject parsed HTML imperatively — {@html} would re-run Svelte's sanitizer
  // pass on every render; a one-shot innerHTML keeps the post static + cheap.
  $effect(() => { if (host && html !== null) host.innerHTML = html; });
</script>

<section class="band blogpost">
 <div class="inner">
  {#if html === null}
    <p class="lede">loading…</p>
  {:else if html === ''}
    <div class="kicker">not found</div>
    <h2>That post isn't here.</h2>
    <p class="lede"><a href="/blog">← back to the blog</a></p>
  {:else}
    <a class="blogback" href="/blog">← blog</a>
    <article bind:this={host}></article>
  {/if}
 </div>
</section>
