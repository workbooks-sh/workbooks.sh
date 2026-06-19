<script lang="ts">
  /**
   * Collapsible reasoning block — the agent's "thinking" for a turn.
   * Auto-expanded while streaming, collapsed once the turn finishes.
   */
  import { Brain, CaretRight } from "phosphor-svelte";
  import { slide } from "svelte/transition";

  let { text, streaming = false }: { text: string; streaming?: boolean } =
    $props();

  // While streaming, force-open; once done, default collapsed. The user can
  // override either way once it's no longer streaming.
  let userOpen = $state<boolean | null>(null);
  const open = $derived(userOpen ?? streaming);

  function toggle() {
    userOpen = !open;
  }
</script>

{#if text.trim()}
  <div class="reasoning" class:streaming>
    <button type="button" class="head" onclick={toggle} aria-expanded={open}>
      <Brain size={14} weight="fill" />
      <span class="label">{streaming ? "Thinking…" : "Thought it through"}</span>
      <span class="chev" class:open><CaretRight size={12} weight="bold" /></span>
    </button>
    {#if open}
      <div class="body" transition:slide={{ duration: 160 }}>{text}</div>
    {/if}
  </div>
{/if}

<style>
  .reasoning {
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-bottom: 8px;
  }
  .head {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    align-self: flex-start;
    padding: 3px 4px;
    border: 0;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
    font-size: 0.78rem;
    border-radius: 6px;
    transition: color 0.12s;
  }
  .head:hover {
    color: var(--color-fg-muted);
  }
  .label {
    font-weight: 500;
  }
  .chev {
    display: inline-flex;
    transition: transform 0.16s ease;
  }
  .chev.open {
    transform: rotate(90deg);
  }
  .body {
    font-size: 0.82rem;
    line-height: 1.55;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border-left: 2px solid color-mix(in srgb, var(--color-brand) 55%, transparent);
    border-radius: 0 8px 8px 0;
    padding: 9px 12px;
    white-space: pre-wrap;
  }
</style>
