<script lang="ts">
  /**
   * WorkbookTab — a work-format (.html workbook) tab with a Rendered ⇄ Source
   * toggle. Rendered = the sandboxed iframe (WorkbookView). Source = a writable,
   * syntax-highlighted CodeMirror editor (CodeView editable). Per-tab local mode.
   */
  import WorkbookView from "./WorkbookView.svelte";
  import CodeView from "./CodeView.svelte";

  let { path }: { path: string } = $props();
  let mode = $state<"rendered" | "source">("rendered");
</script>

<div class="wbtab">
  <div class="modebar">
    <button class:active={mode === "rendered"} onclick={() => (mode = "rendered")}>
      Rendered
    </button>
    <button class:active={mode === "source"} onclick={() => (mode = "source")}>
      Source
    </button>
  </div>
  <div class="body">
    {#if mode === "rendered"}
      <WorkbookView {path} />
    {:else}
      <CodeView {path} editable={true} />
    {/if}
  </div>
</div>

<style>
  .wbtab {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  .modebar {
    flex: 0 0 auto;
    display: flex;
    gap: 2px;
    padding: 0.3rem 0.6rem;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface, var(--color-page));
  }
  .modebar button {
    padding: 0.2rem 0.7rem;
    border: 1px solid transparent;
    border-radius: 6px;
    background: transparent;
    color: var(--color-fg-muted);
    font-size: 0.8rem;
    cursor: pointer;
  }
  .modebar button:hover {
    color: var(--color-fg);
  }
  .modebar button.active {
    color: var(--color-fg);
    background: color-mix(in srgb, var(--color-brand) 12%, transparent);
    border-color: color-mix(in srgb, var(--color-brand) 35%, transparent);
  }
  .body {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
</style>
