<script lang="ts">
  /**
   * ShareCard — preview tile for a published workbook. The thumbnail is
   * the publish-time snapshot (locally generated on the publisher's
   * machine, embedded in the workbook payload). The fallback when no
   * snapshot exists is the artifact's emoji "favicon."
   *
   * Click opens a PreviewPane (static — does not run the workbook).
   */
  import ProvenanceBadge from "./ProvenanceBadge.svelte";
  import { generatePreviewSvg } from "../theme/previewImage";
  import type { Artifact } from "../types";

  let {
    artifact,
    compact = false,
    layout = "horizontal", // "horizontal" or "stacked" (image on top)
    onclick,
  }: {
    artifact: Artifact;
    compact?: boolean;
    layout?: "horizontal" | "stacked";
    onclick?: () => void;
  } = $props();

  // In production: read embedded snapshot from the workbook `.html`.
  // In demo: deterministic SVG per artifact.
  const preview = $derived(generatePreviewSvg(artifact.id + artifact.title));

  // Role tag — every share is a workbook; the tag tells you what it does.
  const roleTag: Record<Artifact["kind"], string> = {
    workbook: "workbook",
    agent: "agent",
    plugin: "plugin",
    skill: "skill",
  };
</script>

<button
  type="button"
  class="card"
  class:compact
  class:stacked={layout === "stacked"}
  {onclick}
>
  <span class="snap" aria-hidden="true">
    <img src={preview} alt="" loading="lazy" />
    <span class="favicon">{artifact.thumbnailEmoji}</span>
  </span>
  <span class="body">
    <span class="meta">
      <span class="role">{roleTag[artifact.kind]}</span>
      <ProvenanceBadge
        state={artifact.verified ? "verified" : "unverified"}
        compact
      />
    </span>
    <span class="title">{artifact.title}</span>
    {#if !compact}
      <span class="blurb">{artifact.blurb}</span>
    {/if}
  </span>
</button>

<style>
  .card {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 0.7rem;
    align-items: stretch;
    width: 100%;
    padding: 0.55rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    text-align: left;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    overflow: hidden;
    transition:
      transform 200ms cubic-bezier(0.22, 1.2, 0.36, 1),
      border-color 200ms ease,
      box-shadow 200ms ease;
  }
  .card.stacked {
    grid-template-columns: 1fr;
    padding: 0;
  }
  .card:hover {
    transform: translateY(-2px);
    border-color: var(--color-border-strong);
    box-shadow:
      0 2px 6px rgba(15, 15, 15, 0.03),
      0 10px 26px rgba(15, 15, 15, 0.05);
  }

  .snap {
    position: relative;
    display: inline-block;
    width: 92px;
    height: 60px;
    border-radius: 8px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    overflow: hidden;
    flex: 0 0 auto;
  }
  .card.compact .snap {
    width: 64px;
    height: 44px;
    border-radius: 7px;
  }
  .card.stacked .snap {
    width: 100%;
    height: 160px;
    border-radius: 0;
    border: 0;
    border-bottom: 1px solid var(--color-border);
  }
  .snap img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    transition: transform 600ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .card:hover .snap img {
    transform: scale(1.04);
  }
  .favicon {
    position: absolute;
    right: 4px;
    bottom: 4px;
    width: 22px;
    height: 22px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    font-size: 0.86rem;
    line-height: 1;
    box-shadow: 0 1px 2px rgba(15, 15, 15, 0.06);
  }
  .card.stacked .favicon {
    right: 8px;
    bottom: 8px;
    width: 28px;
    height: 28px;
    font-size: 1rem;
    border-radius: 7px;
  }

  .body {
    display: inline-flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    padding: 1px 0;
  }
  .card.stacked .body { padding: 0.7rem 0.85rem 0.85rem; gap: 4px; }

  .meta {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 0.7rem;
    color: var(--color-fg-subtle);
  }
  .role {
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 600;
  }
  .title {
    font-size: 0.88rem;
    font-weight: 600;
    letter-spacing: -0.01em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .blurb {
    font-size: 0.78rem;
    color: var(--color-fg-muted);
    line-height: 1.4;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
</style>
