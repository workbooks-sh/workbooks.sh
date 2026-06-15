<script lang="ts">
  /**
   * StackedAvatars — an overlapping row of member avatars with a "+N"
   * overflow chip. Reuses the single-circle Avatar primitive so rings,
   * real photos, and initials-fallback all stay consistent with the rest
   * of the Network surface.
   *
   * Used both to render "who this is shared with" and as a compact
   * trigger that opens the share modal.
   */
  import Avatar from "./Avatar.svelte";

  type Member = {
    handle: string;
    display_name?: string;
    avatar?: string | null;
  };

  let {
    members,
    size = "md",
    max = 5,
    overlap,
    interactive = false,
    onclick,
  }: {
    members: Member[];
    size?: "xs" | "sm" | "md" | "lg";
    max?: number;
    /** px of overlap; defaults scale with size. */
    overlap?: number;
    interactive?: boolean;
    onclick?: () => void;
  } = $props();

  const px: Record<string, number> = { xs: 20, sm: 26, md: 36, lg: 56 };
  const ov = $derived(overlap ?? Math.round(px[size] * 0.36));
  const shown = $derived(members.slice(0, max));
  const extra = $derived(Math.max(0, members.length - max));
</script>

<svelte:element
  this={interactive ? "button" : "div"}
  type={interactive ? "button" : undefined}
  class="stack"
  class:interactive
  style:--ov="{ov}px"
  style:--chip="{px[size]}px"
  {onclick}
  role={interactive ? "button" : undefined}
  tabindex={interactive ? 0 : undefined}
  aria-label={interactive ? "Share with organization" : undefined}
>
  {#if shown.length === 0}
    <span class="empty">No one yet</span>
  {/if}
  {#each shown as m, i (m.handle)}
    <span class="slot" style:z-index={shown.length - i} title={m.display_name ?? m.handle}>
      <Avatar handle={m.handle} avatar={m.avatar ?? null} {size} />
    </span>
  {/each}
  {#if extra > 0}
    <span class="slot more" style:z-index={0} title={`${extra} more`}>
      <span class="more-chip">+{extra}</span>
    </span>
  {/if}
</svelte:element>

<style>
  .stack {
    display: inline-flex;
    align-items: center;
    padding: 0;
    margin: 0;
    border: 0;
    background: transparent;
    font: inherit;
    color: inherit;
  }
  .stack.interactive {
    cursor: pointer;
    border-radius: 999px;
    transition: transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .stack.interactive:hover {
    transform: translateY(-1px);
  }
  .stack.interactive:hover .slot {
    /* fan out slightly on hover so each face peeks through */
    margin-left: calc(var(--ov) * -0.7);
  }
  .slot {
    display: inline-flex;
    margin-left: calc(var(--ov) * -1);
    transition: margin 180ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .slot:first-child {
    margin-left: 0;
  }
  .more-chip {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: var(--chip);
    height: var(--chip);
    border-radius: 50%;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    font-size: calc(var(--chip) * 0.34);
    font-weight: 600;
    letter-spacing: -0.02em;
    box-shadow:
      0 0 0 2px var(--color-page),
      0 0 0 3.5px var(--color-border);
  }
  .empty {
    font-size: 0.78rem;
    color: var(--color-fg-subtle);
  }
</style>
