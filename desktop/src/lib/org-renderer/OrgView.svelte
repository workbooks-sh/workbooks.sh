<script lang="ts">
  /**
   * wb-i38o.9 — OrgView. Renders an `.org` source string to HTML via
   * the OQL WASM parser, applies the GAP / heading-chrome / property
   * drawer transforms from the oql-container spike, and drops the
   * result into the page.
   *
   * Accepts EITHER `source` (preferred — caller owns the read) or
   * `path` (legacy — view reads the file itself). D10's editor wants
   * source so it can pipe live keystrokes into the preview without
   * round-tripping through disk; D9's direct-render callsites still
   * pass path.
   *
   * Visual contract intentionally matches the spike's baked .html
   * output (see org.css). When the spike updates its CSS or
   * transforms, those changes should land here too — keep the two in
   * lockstep.
   */
  import { invoke } from "@tauri-apps/api/core";
  import { onMount } from "svelte";
  import { renderOrg } from "./render";
  import "./org.css";

  let {
    path,
    source,
    showPathHeader = true,
  }: { path?: string; source?: string; showPathHeader?: boolean } = $props();

  let phase = $state<"loading" | "ready" | "error">("loading");
  let html = $state("");
  let error = $state<string | null>(null);

  async function fromSource(src: string) {
    error = null;
    try {
      html = await renderOrg(src);
      phase = "ready";
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
      phase = "error";
    }
  }

  async function fromPath(p: string) {
    phase = "loading";
    html = "";
    try {
      const src = await invoke<string>("read_file_text", { path: p });
      await fromSource(src);
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
      phase = "error";
    }
  }

  onMount(() => {
    if (source !== undefined) fromSource(source);
    else if (path) fromPath(path);
  });

  // React to whichever prop is the live driver. Source wins if both
  // are present (editor case).
  $effect(() => {
    if (source !== undefined) {
      void fromSource(source);
    } else if (path) {
      void fromPath(path);
    }
  });
</script>

<div class="org-doc">
  {#if showPathHeader && path}
    <h1 class="doc-path">{path}</h1>
  {/if}
  {#if phase === "loading"}
    <div class="status-line">Loading…</div>
  {:else if phase === "error"}
    <div class="status-line err">Failed to render: {error}</div>
  {:else}
    <div class="org-content">{@html html}</div>
  {/if}
</div>

<style>
  .status-line {
    opacity: 0.55;
    font-size: 0.95rem;
    padding: 1rem 0;
  }
  .status-line.err {
    color: var(--color-err);
    opacity: 0.85;
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.85rem;
    white-space: pre-wrap;
  }
</style>
