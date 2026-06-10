<script lang="ts">
  /**
   * AgentIcon — single renderer for an agent's visual identity.
   *
   * Decodes the `icon` string per the :agent: entity binding's :ICON:
   * field:
   *
   *   emoji:<glyph>       → render the emoji as text
   *   lucide:<IconName>   → look up the named glyph component (the
   *                         prefix predates the Phosphor migration and
   *                         stays for persisted-icon compatibility)
   *   (anything else)     → fall back to initials from `title`/`slug`
   *
   * Glyph-name resolution uses a curated map — adding a new icon to an
   * agent's :ICON: means adding its component to agent_lucide_map.
   * The picker exposes the same curated set, so authors never
   * reference an icon the renderer can't draw.
   */
  import { LUCIDE_MAP } from "./agent_lucide_map";

  type IconComponent = (typeof LUCIDE_MAP)[string];

  let {
    icon = null,
    title = "",
    slug = "",
    size = 16,
  }: {
    icon?: string | null;
    title?: string;
    slug?: string;
    size?: number;
  } = $props();

  type Decoded =
    | { kind: "emoji"; value: string }
    | { kind: "lucide"; component: IconComponent }
    | { kind: "initials"; value: string };

  function initialsOf(t: string, s: string): string {
    const source = (t || s || "?").trim();
    const parts = source.split(/[\s\-_]+/).filter(Boolean);
    if (parts.length >= 2) {
      // Two-letter — first letter of first two words.
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return source.slice(0, 2).toUpperCase();
  }

  const decoded = $derived<Decoded>(
    (() => {
      if (icon) {
        if (icon.startsWith("emoji:")) {
          return { kind: "emoji" as const, value: icon.slice("emoji:".length) };
        }
        if (icon.startsWith("lucide:")) {
          const name = icon.slice("lucide:".length);
          const c = LUCIDE_MAP[name];
          if (c) return { kind: "lucide" as const, component: c };
          // Unknown lucide name — fall through to initials so the
          // surface degrades gracefully rather than blowing up.
        }
      }
      return { kind: "initials" as const, value: initialsOf(title, slug) };
    })(),
  );
</script>

<span
  class="agent-icon"
  class:emoji={decoded.kind === "emoji"}
  class:lucide={decoded.kind === "lucide"}
  class:initials={decoded.kind === "initials"}
  style:width="{size}px"
  style:height="{size}px"
  style:font-size="{Math.round(size * 0.8)}px"
  aria-hidden="true"
>
  {#if decoded.kind === "emoji"}
    {decoded.value}
  {:else if decoded.kind === "lucide"}
    {@const Comp = decoded.component}
    <Comp size={Math.round(size * 0.8)} weight="fill" />
  {:else}
    <span class="ini" style:font-size="{Math.round(size * 0.45)}px">{decoded.value}</span>
  {/if}
</span>

<style>
  .agent-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    line-height: 1;
  }
  .emoji {
    /* Render emoji at near full size, slightly inset so the picker
     * row baseline aligns. */
    line-height: 1;
  }
  .lucide {
    color: var(--color-fg);
  }
  .initials {
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    border-radius: 4px;
    border: 1px solid var(--color-border);
  }
  .initials .ini {
    font-weight: 600;
    letter-spacing: 0.02em;
  }
</style>
