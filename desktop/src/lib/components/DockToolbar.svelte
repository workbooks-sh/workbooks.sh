<script lang="ts">
  /**
   * DockToolbar (wb-aakl.14) — the top-right toolbar in the titlebar.
   *
   * One button per registered dock panel; clicking toggles that panel in
   * the right dock. The engine status chip stays separate (it sits beside
   * this). Empty until something registers — toolkits (Browser SDK,
   * wb-aakl.15) register here.
   *
   * Two clusters share this component via `kind`:
   *   bench — custom-toolkit shortcuts (everything that isn't the resident
   *           agent); sits left of the search badge.
   *   agent — the resident agent (Waldo) only; its own badge, far right.
   */
  import { dock } from "$lib/bridge/dock.svelte";

  // Panel ids that are agents, not bench toolkits.
  const AGENT_IDS = ["waldo", "agent"];
  let { kind = "bench" }: { kind?: "bench" | "agent" } = $props();
  const panels = $derived(
    dock.panels.filter((p) =>
      kind === "agent" ? AGENT_IDS.includes(p.id) : !AGENT_IDS.includes(p.id),
    ),
  );
</script>

{#each panels as p (p.id)}
  <button
    type="button"
    class="dock-btn"
    class:active={dock.isOpen(p.id)}
    class:icon-only={p.iconOnly}
    data-tauri-drag-region="false"
    title={p.title}
    aria-label={p.title}
    aria-pressed={dock.isOpen(p.id)}
    onclick={() => dock.toggle(p.id)}
  >
    {#if p.icon}
      {@const Icon = p.icon}
      <Icon size={p.iconOnly ? 16 : 12} weight="fill" />
    {/if}
    {#if !p.iconOnly}<span>{p.title}</span>{/if}
  </button>
{/each}

<style>
  /* Badge button — a bordered chip matching the nexus status badge to its
   * left, holding just the wordmark. */
  .dock-btn.icon-only {
    height: 26px;
    padding: 0 11px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .dock-btn.icon-only:hover {
    border-color: var(--color-border-strong);
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .dock-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    /* the titlebar is align-items:stretch; without this a fixed-height
       button falls to the top, leaving space below it. */
    align-self: center;
    gap: 6px;
    height: 26px;
    padding: 0 10px;
    border: 0;
    border-radius: 8px;
    background: transparent;
    color: var(--color-fg-muted);
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 500;
    letter-spacing: 0.02em;
    line-height: 0; /* kill the inline baseline gap below the svg mark */
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }
  .dock-btn :global(svg) { display: block; }
  .dock-btn:hover {
    background: color-mix(in srgb, var(--color-fg) 6%, transparent);
    color: var(--color-fg);
  }
  .dock-btn.active {
    background: var(--color-fg);
    color: var(--color-page);
  }
</style>
