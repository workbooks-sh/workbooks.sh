<script lang="ts" module>
  /**
   * Icon name → Lucide component lookup. We import the specific icons we
   * use (tree-shakeable) and key them by the bare `<Name>` that follows
   * the `lucide:` prefix in an icon value. Canonical Lucide v1 names —
   * deprecated aliases (KanbanSquare, BarChart3, Trello) are avoided.
   */
  import {
    SquareKanban,
    Kanban,
    NotebookPen,
    TrendingUp,
    BookOpen,
    Briefcase,
    Rocket,
    ChartColumn,
    Wrench,
    Package as PackageIcon,
  } from "@lucide/svelte";

  type LucideComponent = typeof SquareKanban;

  export const LUCIDE: Record<string, LucideComponent> = {
    SquareKanban,
    Kanban,
    NotebookPen,
    TrendingUp,
    BookOpen,
    Briefcase,
    Rocket,
    ChartColumn,
    Wrench,
    Package: PackageIcon,
  };
</script>

<script lang="ts">
  /**
   * Icon — the single resolver for the project-wide icon model:
   *
   *   value === ""                     → initials(name)
   *   value.startsWith("lucide:")      → the named Lucide component
   *   value.startsWith("data:image/")  → <img>
   *   otherwise (non-empty)            → emoji / glyph text
   *
   * Both the rail's bare app icon (AppRail) and the folder badge
   * (FolderIcon) route through here so the model has exactly one home.
   */
  let {
    value = "",
    name = "",
    size = 18,
    strokeWidth = 1.8,
  }: {
    value?: string;
    /** Fallback label for the initials case. */
    name?: string;
    /** Lucide glyph size (px). Emoji/initials are sized by the host CSS. */
    size?: number;
    strokeWidth?: number;
  } = $props();

  function initials(n: string): string {
    const words = n.trim().split(/[\s\-_]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return (n || "?").slice(0, 2).toUpperCase();
  }

  const lucideName = $derived(
    value.startsWith("lucide:") ? value.slice("lucide:".length) : null,
  );
  const LucideComp = $derived(lucideName ? LUCIDE[lucideName] ?? null : null);
  const isImage = $derived(value.startsWith("data:image/"));
</script>

{#if LucideComp}
  <svelte:component this={LucideComp} {size} {strokeWidth} aria-hidden="true" />
{:else if isImage}
  <img src={value} alt="" />
{:else if value}
  <span class="emoji" aria-hidden="true">{value}</span>
{:else}
  <span class="initials" aria-hidden="true">{initials(name)}</span>
{/if}

<style>
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .emoji {
    line-height: 1;
  }
  .initials {
    font-weight: 600;
    letter-spacing: 0.02em;
  }
</style>
