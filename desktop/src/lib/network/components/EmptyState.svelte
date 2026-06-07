<script lang="ts">
  /**
   * EmptyState — charming reusable empty surface.
   *
   * A neutral backdrop bubble (.b1) holds the glyph. Two satellite
   * bubbles (.b2 top-right, .b3 bottom-left) take per-page color via
   * a single `hue` prop and render as nicely-shaded spheres — the
   * top one brighter (closer to the light source at upper-left), the
   * bottom one darker but still lit, both with a subtle outer-glow
   * that gives them a tactile pop.
   */
  import type { Snippet } from "svelte";

  let {
    title,
    blurb,
    glyph = "✷",
    /** Color hue (0–360) for the satellite bubbles. Set per-tab so
     *  each surface reads with its own personality:
     *    Inbox 220 (blue), Friends 340 (rose), Groups 270 (purple),
     *    Subscriptions 150 (teal-green), Feed 35 (amber),
     *    Profile 190 (cyan). Omit for the neutral default (grey). */
    hue = null,
    cta,
  }: {
    title: string;
    blurb: string;
    glyph?: string;
    hue?: number | null;
    cta?: Snippet;
  } = $props();
</script>

<div class="empty" style:--hue={hue ?? 0} style:--sat={hue === null ? "0%" : "70%"}>
  <div class="illus" aria-hidden="true">
    <span class="bubble b1"></span>
    <span class="bubble b2"></span>
    <span class="bubble b3"></span>
    <span class="glyph">{glyph}</span>
  </div>
  <h3 class="title">{title}</h3>
  <p class="blurb">{blurb}</p>
  {#if cta}
    <div class="cta">{@render cta()}</div>
  {/if}
</div>

<style>
  .empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    padding: 2.6rem 1.5rem;
    gap: 0.6rem;
  }
  .illus {
    position: relative;
    width: 100px;
    height: 100px;
    margin-bottom: 0.2rem;
  }
  .bubble {
    position: absolute;
    border-radius: 50%;
  }
  /* Neutral backdrop bubble — holds the glyph in front. Unchanged. */
  .b1 {
    width: 88px;
    height: 88px;
    top: 6px;
    left: 6px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    animation: float1 6s ease-in-out infinite alternate;
  }
  /* Top satellite — brighter sphere. Highlight at 28% 25% to match a
     light source roughly at upper-left. Bright core (~78% L) → mid
     (~55% L) → rim shadow (~38% L). A soft outer drop-shadow tinted
     with the same hue gives it a little pop off the page. */
  .b2 {
    width: 36px;
    height: 36px;
    top: 0;
    right: 4px;
    background:
      radial-gradient(
        circle at 28% 25%,
        hsl(var(--hue), var(--sat), 88%) 0%,
        hsl(var(--hue), var(--sat), 70%) 28%,
        hsl(var(--hue), var(--sat), 50%) 70%,
        hsl(var(--hue), var(--sat), 38%) 100%
      );
    /* Inset rim shadow on the dark side + soft outer glow */
    box-shadow:
      inset -2px -3px 5px hsla(var(--hue), var(--sat), 25%, 0.45),
      inset 2px 2px 3px hsla(var(--hue), var(--sat), 95%, 0.35),
      0 4px 14px hsla(var(--hue), var(--sat), 50%, 0.28);
    animation: float2 5.5s ease-in-out infinite alternate;
  }
  /* Bottom satellite — darker sphere, still lit from upper-left. Less
     contrast in highlight, deeper shadow side. Outer glow is dimmer. */
  .b3 {
    width: 26px;
    height: 26px;
    bottom: 0;
    left: 0;
    background:
      radial-gradient(
        circle at 30% 28%,
        hsl(var(--hue), var(--sat), 72%) 0%,
        hsl(var(--hue), var(--sat), 52%) 32%,
        hsl(var(--hue), var(--sat), 34%) 75%,
        hsl(var(--hue), var(--sat), 22%) 100%
      );
    box-shadow:
      inset -2px -2px 4px hsla(var(--hue), var(--sat), 15%, 0.5),
      inset 1px 1px 2px hsla(var(--hue), var(--sat), 85%, 0.28),
      0 3px 10px hsla(var(--hue), var(--sat), 35%, 0.22);
    animation: float3 7s ease-in-out infinite alternate;
  }
  @keyframes float1 {
    from { transform: translate(0, 0); }
    to { transform: translate(-3px, 3px); }
  }
  @keyframes float2 {
    from { transform: translate(0, 0); }
    to { transform: translate(2px, -3px); }
  }
  @keyframes float3 {
    from { transform: translate(0, 0); }
    to { transform: translate(3px, 2px); }
  }
  .glyph {
    position: absolute;
    inset: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 2.2rem;
    color: var(--color-fg-muted);
    /* Keep glyph above both satellites (no z-index war between them) */
    z-index: 2;
  }
  .title {
    margin: 0.4rem 0 0;
    font-size: 0.98rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .blurb {
    margin: 0;
    max-width: 36ch;
    color: var(--color-fg-muted);
    font-size: 0.85rem;
    line-height: 1.5;
  }
  .cta {
    margin-top: 0.7rem;
  }

  /* Dark mode — slightly tone down the highlights so the sphere
     doesn't over-burn against a dark page. */
  @media (prefers-color-scheme: dark) {
    .b2 {
      background:
        radial-gradient(
          circle at 28% 25%,
          hsl(var(--hue), var(--sat), 78%) 0%,
          hsl(var(--hue), var(--sat), 58%) 32%,
          hsl(var(--hue), var(--sat), 38%) 75%,
          hsl(var(--hue), var(--sat), 26%) 100%
        );
      box-shadow:
        inset -2px -3px 5px hsla(var(--hue), var(--sat), 15%, 0.55),
        inset 2px 2px 3px hsla(var(--hue), var(--sat), 92%, 0.28),
        0 4px 14px hsla(var(--hue), var(--sat), 50%, 0.34);
    }
    .b3 {
      background:
        radial-gradient(
          circle at 30% 28%,
          hsl(var(--hue), var(--sat), 60%) 0%,
          hsl(var(--hue), var(--sat), 42%) 35%,
          hsl(var(--hue), var(--sat), 26%) 78%,
          hsl(var(--hue), var(--sat), 16%) 100%
        );
      box-shadow:
        inset -2px -2px 4px hsla(var(--hue), var(--sat), 8%, 0.6),
        inset 1px 1px 2px hsla(var(--hue), var(--sat), 80%, 0.22),
        0 3px 10px hsla(var(--hue), var(--sat), 30%, 0.28);
    }
  }
</style>
