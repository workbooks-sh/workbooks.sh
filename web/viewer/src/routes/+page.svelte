<script lang="ts">
  import { goto } from "$app/navigation";

  let url = $state("");
  let error = $state<string | null>(null);

  function go() {
    error = null;
    const trimmed = url.trim();
    if (!trimmed) {
      error = "Paste a workbooks.sh/w/<rid> URL or just a rad:z… RID.";
      return;
    }
    // Accept either a full URL or a bare rad:z… RID
    let rid: string | null = null;
    const ridMatch = trimmed.match(/^(rad:z[1-9A-HJ-NP-Za-km-z]{20,})$/);
    if (ridMatch) {
      rid = ridMatch[1];
    } else {
      // Look for /w/<rid> in the URL path
      try {
        const u = new URL(trimmed);
        const m = u.pathname.match(/\/w\/(rad:z[1-9A-HJ-NP-Za-km-z]{20,})/);
        if (m) rid = m[1];
      } catch {
        /* not a URL */
      }
    }
    if (!rid) {
      error = "Couldn't find a Radicle RID in that input.";
      return;
    }
    goto(`/w/${encodeURIComponent(rid)}`);
  }
</script>

<svelte:head>
  <title>Workbooks Viewer — open a shared workbook</title>
</svelte:head>

<div class="hero">
  <h1>Open a shared workbook</h1>
  <p class="sub">
    Paste a <code>workbooks.sh/w/&lt;rid&gt;</code> URL or a bare
    <code>rad:z…</code> RID to view a workbook + verify its provenance.
  </p>

  <form
    onsubmit={(e) => {
      e.preventDefault();
      go();
    }}
    class="form"
  >
    <!-- svelte-ignore a11y_autofocus -->
    <input
      type="text"
      bind:value={url}
      placeholder="workbooks.sh/w/rad:z3HhM…"
      autofocus
    />
    <button type="submit">Open</button>
  </form>

  {#if error}
    <div class="err">{error}</div>
  {/if}

  <div class="note">
    Workbooks are signed by their publisher's identity key. We verify in
    your browser using WebCrypto — no server can see what you're opening.
  </div>
</div>

<style>
  .hero {
    max-width: 640px;
    margin: 8vh auto 0;
    text-align: center;
  }
  h1 {
    margin: 0;
    font-size: 2rem;
    font-weight: 700;
    letter-spacing: -0.01em;
  }
  .sub {
    margin: 14px 0 28px;
    color: var(--color-fg-muted);
    font-size: 0.92rem;
    line-height: 1.5;
  }
  code {
    font-family: var(--font-mono);
    font-size: 0.82rem;
    padding: 1.5px 5px;
    border-radius: 4px;
    background: var(--color-surface-soft);
  }
  .form {
    display: flex;
    gap: 8px;
    margin: 0 auto;
    max-width: 560px;
  }
  input {
    flex: 1;
    padding: 11px 14px;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg);
    font-size: 0.92rem;
    font-family: var(--font-mono);
  }
  input:focus {
    outline: none;
    border-color: var(--color-fg);
  }
  button {
    padding: 11px 22px;
    border-radius: 8px;
    border: 0;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 0.92rem;
    font-weight: 600;
    cursor: pointer;
  }
  button:hover {
    opacity: 0.86;
  }
  .err {
    margin-top: 14px;
    padding: 9px 14px;
    border-radius: 6px;
    background: rgba(220, 60, 60, 0.08);
    border: 1px solid rgba(220, 60, 60, 0.22);
    color: rgb(180, 50, 50);
    font-size: 0.85rem;
    text-align: left;
  }
  .note {
    margin-top: 38px;
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    line-height: 1.55;
  }
</style>
