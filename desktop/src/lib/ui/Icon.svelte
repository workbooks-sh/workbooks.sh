<script lang="ts" module>
  /**
   * Legacy stored values (lucide:<Name>) → Material Icon Theme defs.
   * The phosphor glyph era is over for item icons — old values persisted
   * on disk resolve to their closest material icon instead.
   *
   * GRAMMAR SYNC — single source of truth, two homes: the value grammar
   * this component resolves (and this legacy map) is ALSO exposed to
   * agents by the `icons` toolkit (toolkits/icons/src/cli.js — `icons
   * grammar`). Change the grammar or this map in one place → change the
   * other; toolkits/icons/test/icons.test.mjs asserts the map stays in sync.
   */
  export const LEGACY_GLYPHS: Record<string, string> = {
    Kanban: "todo",
    SquareKanban: "todo",
    Notebook: "document",
    NotebookPen: "document",
    TrendUp: "table",
    TrendingUp: "table",
    ChartBar: "table",
    ChartColumn: "table",
    BookOpen: "readme",
    Briefcase: "lib",
    Rocket: "rocket",
    Wrench: "settings",
    Package: "zip",
  };
</script>

<script lang="ts">
  /**
   * Icon — the single resolver for the project-wide icon model
   * (the universal icon library, wb-5fl.15):
   *
   *   value === ""                     → initials(name)
   *   value.startsWith("mi:")          → Material Icon Theme svg (by name)
   *   value.startsWith("lobe:")        → LobeHub brand svg (AI/dev logos,
   *                                      fetched + browser-cached)
   *   value.startsWith("lucide:")      → legacy → mapped material icon
   *   value.startsWith("data:image/")  → <img>
   *   otherwise (non-empty)            → emoji / glyph text
   */
  import { materialIconUrl } from "$lib/ui/materialIcon";

  const LOBE_BASE =
    "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-svg/icons";

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

  /** mi:<def> directly, or a legacy lucide:<Name> mapped to its def. */
  const miUrl = $derived.by(() => {
    if (value.startsWith("mi:")) return materialIconUrl(value.slice(3));
    if (value.startsWith("lucide:")) {
      const def = LEGACY_GLYPHS[value.slice("lucide:".length)];
      return def ? materialIconUrl(def) : null;
    }
    return null;
  });
  const lobeUrl = $derived(
    value.startsWith("lobe:")
      ? `${LOBE_BASE}/${value.slice("lobe:".length)}.svg`
      : null,
  );
  // LobeHub mono brand marks (slug WITHOUT the `-color` suffix, e.g.
  // `openrouter`) ship as a single-color shape — usually black, so they vanish
  // in dark mode when drawn as an <img>. Render them as a CSS mask filled with
  // currentColor so they follow the text color (white on dark, dark on light).
  // Multi-color marks (`*-color`, e.g. `gemini-color`) stay as <img>.
  const lobeMono = $derived(!!lobeUrl && !value.endsWith("-color"));
  const isImage = $derived(value.startsWith("data:image/"));
  /** Unresolvable prefixed values fall through to initials, never to
   *  raw text like "lucide:Foo". */
  const isPrefixed = $derived(/^(lucide|mi|lobe):/.test(value));
</script>

{#if miUrl}
  <img src={miUrl} alt="" style="width: {size}px; height: {size}px;" />
{:else if lobeMono}
  <span
    class="lobe-mono"
    aria-hidden="true"
    style="width: {size}px; height: {size}px; --lobe-mask: url('{lobeUrl}');"
  ></span>
{:else if lobeUrl}
  <img src={lobeUrl} alt="" style="width: {size}px; height: {size}px;" loading="lazy" />
{:else if isImage}
  <img src={value} alt="" />
{:else if value && !isPrefixed}
  <span class="emoji" aria-hidden="true" style="font-size: {size}px;">{value}</span>
{:else}
  <span class="initials" aria-hidden="true" style="font-size: {Math.round(size * 0.62)}px;">{initials(name)}</span>
{/if}

<style>
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .lobe-mono {
    display: inline-block;
    flex: none;
    background-color: currentColor;
    -webkit-mask: var(--lobe-mask) center / contain no-repeat;
    mask: var(--lobe-mask) center / contain no-repeat;
  }
  .emoji {
    line-height: 1;
  }
  .initials {
    font-weight: 600;
    letter-spacing: 0.02em;
  }
</style>
