<script lang="ts">
  /**
   * WorkbookView — the "frontend as workbook" dogfood. The desktop app asks the
   * RUNTIME to weave a stored Org workbook → HTML (GET /api/w/:id/html, rendered
   * by the OQL kernel) and displays it. The webview renders the runtime's own
   * output — the app eating the workbook format it ships.
   */
  import { FileText, RefreshCw } from "@lucide/svelte";
  import { rt, getRuntime } from "$lib/runtime";

  let id = $state("");
  let html = $state("");
  let err = $state("");
  let busy = $state(false);

  async function render() {
    err = "";
    html = "";
    busy = true;
    try {
      const info = await getRuntime();
      if (info.state === "spa") {
        err = "No runtime connected — launch the desktop shell to weave workbooks.";
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
</script>

<section class="workbook">
  <form
    class="bar"
    onsubmit={(e) => {
      e.preventDefault();
      void render();
    }}
  >
    <FileText size={18} strokeWidth={1.6} />
    <input bind:value={id} placeholder="workbook id" />
    <button disabled={busy || !id}>
      <RefreshCw size={15} strokeWidth={1.8} class={busy ? "spin" : ""} />
      Render
    </button>
  </form>

  {#if err}
    <p class="err">{err}</p>
  {/if}

  {#if html}
    <!-- The runtime wove this HTML from Org; we render its output verbatim. -->
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
