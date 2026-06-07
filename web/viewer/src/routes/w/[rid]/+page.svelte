<script lang="ts">
  import WorkbookProvenance from "$lib/components/WorkbookProvenance.svelte";
  import type { PageData } from "./$types";

  let { data }: { data: PageData } = $props();

  // The desktop deep link — opens this workbook in Workbooks Desktop
  // via the workbooks:// custom URL scheme.
  const desktopLink = $derived(`workbooks://open?rid=${encodeURIComponent(data.rid)}`);
  // For users without the desktop installed, fall through to the
  // install page on workbooks.sh.
  const installLink = "https://workbooks.sh/install";

  let iframeBlobUrl = $state<string | null>(null);

  $effect(() => {
    if (iframeBlobUrl) URL.revokeObjectURL(iframeBlobUrl);
    iframeBlobUrl = null;
    if (data.html) {
      const blob = new Blob([data.html], { type: "text/html" });
      iframeBlobUrl = URL.createObjectURL(blob);
    }
  });
</script>

<svelte:head>
  <title>{data.rid} — Workbooks Viewer</title>
</svelte:head>

<div class="page">
  <div class="meta-bar">
    <div class="rid-block">
      <span class="label">RID</span>
      <code class="rid">{data.rid}</code>
      {#if data.source === "demo"}
        <span class="source-tag demo">demo (gateway unreachable)</span>
      {/if}
    </div>
    <div class="actions">
      <a class="btn ghost" href={desktopLink}>Open in Workbooks Desktop</a>
      <a class="btn ghost" href={installLink}>Install Desktop</a>
    </div>
  </div>

  {#if data.html}
    <div class="provenance">
      <WorkbookProvenance
        html={data.html}
        showModifiedBanner={true}
        showLineageToggle={true}
        rid={data.rid}
      />
    </div>

    {#if iframeBlobUrl}
      <iframe
        src={iframeBlobUrl}
        sandbox="allow-scripts"
        title="Workbook content"
      ></iframe>
    {/if}
  {:else}
    <div class="err">
      <h2>Could not load workbook</h2>
      <p>{data.error ?? "Unknown error"}</p>
    </div>
  {/if}
</div>

<style>
  .page {
    max-width: 960px;
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .meta-bar {
    display: flex;
    align-items: center;
    gap: 18px;
    padding: 12px 14px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    flex-wrap: wrap;
  }
  .rid-block {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }
  .label {
    font-size: 0.7rem;
    color: var(--color-fg-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    font-weight: 600;
  }
  .rid {
    font-family: var(--font-mono);
    font-size: 0.78rem;
    padding: 3px 8px;
    border-radius: 5px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    word-break: break-all;
  }
  .source-tag {
    font-size: 0.7rem;
    padding: 2px 7px;
    border-radius: 999px;
    font-weight: 600;
  }
  .source-tag.demo {
    background: rgba(225, 145, 30, 0.12);
    border: 1px solid rgba(225, 145, 30, 0.32);
    color: rgb(150, 95, 10);
  }
  .actions {
    margin-left: auto;
    display: flex;
    gap: 8px;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 7px 13px;
    border-radius: 6px;
    font-size: 0.82rem;
    font-weight: 600;
    text-decoration: none;
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    background: var(--color-surface-soft);
  }
  .btn:hover {
    background: var(--color-border);
  }
  .provenance {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px 14px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
  }
  iframe {
    width: 100%;
    height: 70vh;
    min-height: 480px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: white;
  }
  .err {
    padding: 28px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    color: var(--color-fg-muted);
    text-align: center;
  }
  .err h2 {
    margin-top: 0;
    color: var(--color-fg);
  }
</style>
