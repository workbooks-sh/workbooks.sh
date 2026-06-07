<script lang="ts">
  /**
   * Avatar — a single circle with emoji/initials/image + personal-color
   * ring derived via iconAccent. The ring is the chrome's only color
   * accent per CLAUDE.md (state colors are reserved for semantic state).
   */
  import { personalColor } from "../theme/personalColor";

  type Size = "xs" | "sm" | "md" | "lg" | "xl";

  let {
    handle,
    avatar = null,
    size = "md",
    ring = true,
    verified = false,
  }: {
    handle: string;
    avatar?: string | null;
    size?: Size;
    ring?: boolean;
    verified?: boolean;
  } = $props();

  const sizes: Record<Size, { px: number; font: number; ring: number }> = {
    xs: { px: 20, font: 11, ring: 1.5 },
    sm: { px: 26, font: 14, ring: 1.5 },
    md: { px: 36, font: 19, ring: 2 },
    lg: { px: 56, font: 30, ring: 2.5 },
    xl: { px: 96, font: 52, ring: 3 },
  };

  const dim = $derived(sizes[size]);
  const color = $derived(personalColor(handle, avatar));
  const initials = $derived(
    handle
      .slice(0, 2)
      .toUpperCase()
      .padEnd(2, handle.slice(0, 1).toUpperCase()),
  );
  const isImage = $derived(!!avatar && avatar.startsWith("data:image/"));
</script>

<span
  class="avatar"
  class:has-ring={ring}
  style:--av-px="{dim.px}px"
  style:--av-font="{dim.font}px"
  style:--av-ring="{dim.ring}px"
  style:--av-ring-color={color.ring}
  style:--av-fill-color={color.fill}
  title={`@${handle}`}
>
  {#if isImage}
    <img src={avatar} alt={`@${handle}`} />
  {:else if avatar}
    <span class="glyph">{avatar}</span>
  {:else}
    <span class="initials">{initials}</span>
  {/if}
  {#if verified}
    <span class="verified-dot" aria-label="verified"></span>
  {/if}
</span>

<style>
  .avatar {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: var(--av-px);
    height: var(--av-px);
    border-radius: 50%;
    background: var(--color-surface-soft);
    overflow: visible;
    flex: 0 0 auto;
    transition: transform 280ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .avatar.has-ring {
    box-shadow:
      0 0 0 var(--av-ring) var(--color-page),
      0 0 0 calc(var(--av-ring) + 1.5px) var(--av-ring-color);
  }
  .avatar img {
    width: 100%;
    height: 100%;
    border-radius: 50%;
    object-fit: cover;
    display: block;
  }
  .glyph,
  .initials {
    font-size: var(--av-font);
    line-height: 1;
  }
  .initials {
    font-weight: 600;
    color: var(--color-fg-muted);
    letter-spacing: -0.02em;
  }
  .verified-dot {
    position: absolute;
    right: -1px;
    bottom: -1px;
    width: 32%;
    height: 32%;
    min-width: 8px;
    min-height: 8px;
    border-radius: 50%;
    background: rgb(34, 160, 105);
    box-shadow: 0 0 0 1.5px var(--color-page);
  }
</style>
