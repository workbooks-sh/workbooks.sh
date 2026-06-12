<script lang="ts">
  /**
   * wb-i38o.8 — TextView. Fallback for file extensions we don't have a
   * dedicated renderer for (binary-ish formats, unknown languages).
   * Surfaces the file as plain text with a warning header so the user
   * knows it might not be intended as text.
   */
  import { invoke } from "@tauri-apps/api/core";
  import { onMount } from "svelte";

  let { path }: { path: string } = $props();

  let content = $state("");
  let error = $state<string | null>(null);
  let loading = $state(true);

  async function load(p: string) {
    loading = true;
    error = null;
    try {
      content = await invoke<string>("read_file_text", { path: p });
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      loading = false;
    }
  }

  onMount(() => load(path));
  $effect(() => {
    if (path) load(path);
  });
</script>

<div class="wrap">
  <div class="warn">
    Plain-text fallback — no dedicated renderer for this file extension.
  </div>
  {#if loading}
    <div class="status">Loading…</div>
  {:else if error}
    <div class="status err">{error}</div>
  {:else}
    <pre>{content}</pre>
  {/if}
</div>

<style>
  .wrap {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .warn {
    padding: 0.5rem 1rem;
    background: color-mix(in srgb, var(--color-warn) 12%, transparent);
    color: var(--color-warn);
    font-size: 12px;
    border-bottom: 1px solid var(--color-border);
  }
  pre {
    flex: 1 1 auto;
    overflow: auto;
    margin: 0;
    padding: 1rem;
    font-family: var(--font-mono), ui-monospace, Menlo, Consolas, monospace;
    font-size: 13px;
    line-height: 1.55;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .status {
    padding: 1rem;
    color: var(--color-fg-muted);
    font-size: 0.85rem;
  }
  .status.err {
    color: var(--color-err); /* app-wide error literal — no error token in the canon */
    font-family: var(--font-mono), ui-monospace, monospace;
  }
</style>
