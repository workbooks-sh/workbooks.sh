<script lang="ts">
  /**
   * HandleChip — clickable @handle. Two variants:
   *   - "pill" — standalone with mini avatar + ring (use where no other
   *     avatar is already in the row)
   *   - "inline" — just the @handle text (use inside a row that already
   *     shows the person's main avatar, so we don't double up)
   */
  import Avatar from "./Avatar.svelte";

  let {
    handle,
    avatar = null,
    variant = "pill",
    onclick,
  }: {
    handle: string;
    /** Optional avatar (emoji or data URL). When omitted the Avatar
     *  component renders a deterministic monogram from the handle. */
    avatar?: string | null;
    variant?: "pill" | "inline";
    onclick?: () => void;
  } = $props();
</script>

{#if variant === "inline"}
  <button type="button" class="inline" {onclick}>@{handle}</button>
{:else}
  <button type="button" class="pill" {onclick}>
    <Avatar
      {handle}
      {avatar}
      size="xs"
      ring
    />
    <span>@{handle}</span>
  </button>
{/if}

<style>
  .pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 9px 3px 3px;
    border-radius: 999px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.78rem;
    font-weight: 500;
    cursor: pointer;
    transition:
      background 160ms ease,
      border-color 160ms ease,
      transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .pill:hover {
    background: var(--color-surface);
    border-color: var(--color-border-strong);
    transform: translateY(-1px);
  }
  .inline {
    display: inline-flex;
    align-items: center;
    padding: 1px 5px;
    background: transparent;
    border: 0;
    border-radius: 4px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.86rem;
    font-weight: 600;
    letter-spacing: -0.01em;
    cursor: pointer;
    transition: background 140ms ease;
  }
  .inline:hover { background: var(--color-surface-soft); }
</style>
