<script lang="ts" module>
  /**
   * Icon name → Phosphor component lookup (solid / weight="fill" app-wide).
   * Keyed by the bare `<Name>` that follows the `lucide:` prefix in stored
   * icon values — the prefix predates the Phosphor migration and stays for
   * backward compatibility with icons persisted on disk; old Lucide names
   * are aliased to their Phosphor equivalents.
   */
  import {
    Kanban,
    Notebook,
    TrendUp,
    BookOpen,
    Briefcase,
    Rocket,
    ChartBar,
    Wrench,
    Package as PackageIcon,
  } from "phosphor-svelte";

  type IconComponent = typeof Kanban;

  export const GLYPHS: Record<string, IconComponent> = {
    Kanban,
    Notebook,
    TrendUp,
    BookOpen,
    Briefcase,
    Rocket,
    ChartBar,
    Wrench,
    Package: PackageIcon,
    // Legacy Lucide names persisted in package/workspace metadata.
    SquareKanban: Kanban,
    NotebookPen: Notebook,
    TrendingUp: TrendUp,
    ChartColumn: ChartBar,
  };
</script>

<script lang="ts">
  /**
   * Icon — the single resolver for the project-wide icon model:
   *
   *   value === ""                     → initials(name)
   *   value.startsWith("lucide:")      → the named glyph component (solid)
   *   value.startsWith("data:image/")  → <img>
   *   otherwise (non-empty)            → emoji / glyph text
   */
  let {
    value = "",
    name = "",
    size = 18,
  }: {
    value?: string;
    /** Fallback label for the initials case. */
    name?: string;
    /** Glyph size (px). Emoji/initials are sized by the host CSS. */
    size?: number;
  } = $props();

  function initials(n: string): string {
    const words = n.trim().split(/[\s\-_]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return (n || "?").slice(0, 2).toUpperCase();
  }

  const glyphName = $derived(
    value.startsWith("lucide:") ? value.slice("lucide:".length) : null,
  );
  const GlyphComp = $derived(glyphName ? GLYPHS[glyphName] ?? null : null);
  const isImage = $derived(value.startsWith("data:image/"));
</script>

{#if GlyphComp}
  <GlyphComp {size} weight="fill" aria-hidden="true" />
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
