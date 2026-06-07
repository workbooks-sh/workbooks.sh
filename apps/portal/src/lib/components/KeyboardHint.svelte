<script lang="ts">
  interface Props {
    keys: string[];
    label?: string;
  }
  let { keys, label }: Props = $props();
</script>

<span class="hint">
  {#each keys as key, i}
    <kbd>{key}</kbd>{#if i < keys.length - 1}<span class="sep">+</span>{/if}
  {/each}
  {#if label}
    <span class="label">{label}</span>
  {/if}
</span>

<style>
  .hint {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    color: var(--fg-subtle);
    font-size: 11px;
  }

  kbd {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 1px 5px;
    border: 1px solid var(--border-strong);
    background: var(--bg-soft);
    color: var(--fg-muted);
    font-family: var(--mono);
    font-size: 11px;
    min-width: 20px;
  }

  .sep {
    color: var(--fg-subtle);
  }

  .label {
    margin-left: 4px;
    color: var(--fg-subtle);
  }
</style>
