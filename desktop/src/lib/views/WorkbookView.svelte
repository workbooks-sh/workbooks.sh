<script lang="ts">
  /**
   * WorkbookView — the app renders its own format. The LOCAL embedded kernel
   * (oql.wasm) weaves Org → HTML in-process: no runtime, no Docker, offline. A
   * stored workbook can also be pulled from the runtime by id WHEN connected
   * (optional server tier), but the default path needs nothing.
   */
  import { FileText, RefreshCw, Cloud } from "@lucide/svelte";
  import { weave, hasLocalKernel } from "$lib/kernel";
  import { rt, getRuntime } from "$lib/runtime";

  const sample = "* My Workbook\n\nThe app renders *its own format* — locally, via the\nembedded =oql.wasm= kernel. No server required.\n\n** A list\n- weave\n- tangle\n- validate\n";

  let org = $state(sample);
  let html = $state("");
  let err = $state("");
  let busy = $state(false);

  async function weaveLocal() {
    err = "";
    busy = true;
    try {
      if (!hasLocalKernel()) {
        err = "Local weave needs the desktop shell (oql.wasm).";
        return;
      }
      html = await weave(org);
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  // Optional: pull a stored workbook's woven HTML from the runtime (when up).
  async function loadFromRuntime(id: string) {
    err = "";
    busy = true;
    try {
      const info = await getRuntime();
      if (info.state !== "up") {
        err = "Runtime not connected (the optional server tier).";
        return;
      }
      const res = await rt(`/api/w/${encodeURIComponent(id)}/html`);
      if (!res.ok) {
        err = `runtime → HTTP ${res.status}`;
        return;
      }
      html = await res.text();
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  let id = $state("");
</script>

<section class="workbook">
  <div class="bar">
    <FileText size={18} strokeWidth={1.6} />
    <button disabled={busy} onclick={() => void weaveLocal()}>
      <RefreshCw size={15} strokeWidth={1.8} />
      Weave locally
    </button>
    <span class="spacer"></span>
    <input bind:value={id} placeholder="stored id (runtime)" />
    <button class="ghost" disabled={busy || !id} onclick={() => void loadFromRuntime(id)}>
      <Cloud size={15} strokeWidth={1.8} />
      From runtime
    </button>
  </div>

  <textarea bind:value={org} spellcheck="false"></textarea>

  {#if err}
    <p class="err">{err}</p>
  {/if}

  {#if html}
    <!-- HTML woven by the local kernel (or the runtime) from Org, rendered verbatim. -->
    <article class="woven">{@html html}</article>
  {/if}
</section>

<style>
  .workbook {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1rem;
    height: 100%;
    overflow: auto;
  }
  .bar {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .bar input {
    flex: 1;
    padding: 0.4rem 0.6rem;
    border: 1px solid var(--border, #2a2a2a);
    border-radius: 6px;
    background: transparent;
    color: inherit;
  }
  .bar button {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.4rem 0.7rem;
    border-radius: 6px;
    cursor: pointer;
  }
  .bar button.ghost {
    opacity: 0.8;
  }
  .spacer {
    flex: 1;
  }
  textarea {
    min-height: 9rem;
    resize: vertical;
    padding: 0.6rem 0.75rem;
    border: 1px solid var(--border, #2a2a2a);
    border-radius: 8px;
    background: transparent;
    color: inherit;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.85rem;
    line-height: 1.5;
  }
  .err {
    color: #e06c75;
    font-size: 0.9rem;
  }
  .woven {
    border: 1px solid var(--border, #2a2a2a);
    border-radius: 8px;
    padding: 1rem 1.25rem;
    background: var(--surface, #1116);
  }
</style>
