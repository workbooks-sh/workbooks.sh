<script lang="ts">
  /**
   * DockToolbar (wb-aakl.14) — the top-right toolbar in the titlebar.
   *
   * One button per registered dock panel; clicking toggles that panel in the
   * right dock. Buttons are ICON-ONLY — the name shows in a custom hover
   * tooltip (a little tail pointing up to the icon, the label below it), so
   * the bar stays compact but you can recall what each one is.
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

  // Custom tooltip — portaled to <body> so it escapes the titlebar's clipped
  // overflow, fixed-positioned just below the hovered icon.
  let tip = $state<{ x: number; y: number; label: string } | null>(null);
  function showTip(e: MouseEvent | FocusEvent, label: string) {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    tip = { x: r.left + r.width / 2, y: r.bottom + 8, label };
  }
  function hideTip() {
    tip = null;
  }

  // Minimal portal: move the node to document.body on mount, remove on destroy.
  function portal(node: HTMLElement) {
    document.body.appendChild(node);
    return { destroy: () => node.remove() };
  }
</script>

{#each panels as p (p.id)}
  <button
    type="button"
    class="dock-btn"
    class:active={dock.isOpen(p.id)}
    class:icon-only={p.iconOnly}
    data-tauri-drag-region="false"
    aria-label={p.title}
    aria-pressed={dock.isOpen(p.id)}
    onmouseenter={(e) => showTip(e, p.title)}
    onmouseleave={hideTip}
    onfocus={(e) => showTip(e, p.title)}
    onblur={hideTip}
    onclick={() => dock.toggle(p.id)}
  >
    {#if p.icon}
      {@const Icon = p.icon}
      <Icon size={p.iconOnly ? 16 : 15} weight="fill" />
    {/if}
  </button>
{/each}

{#if tip}
  <div
    use:portal
    class="dock-tip"
    role="tooltip"
    style="left:{tip.x}px; top:{tip.y}px;"
  >
    {tip.label}
  </div>
{/if}

<style>
  .dock-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    /* the titlebar is align-items:stretch; without this a fixed-height
       button falls to the top, leaving space below it. */
    align-self: center;
    height: 26px;
    width: 26px;
    border: 1px solid transparent;
    border-radius: 8px;
    background: transparent;
    color: var(--color-fg-muted);
    line-height: 0; /* kill the inline baseline gap below the svg mark */
    cursor: pointer;
    transition: background 0.15s, color 0.15s, border-color 0.15s;
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

  /* Waldo's wide wordmark — a bordered badge, auto-width to fit the mark. */
  .dock-btn.icon-only {
    width: auto;
    padding: 0 11px;
    border-color: var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .dock-btn.icon-only:hover {
    border-color: var(--color-border-strong);
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .dock-btn.icon-only.active {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: var(--color-fg);
  }

  /* Custom tooltip — ink chip with an upward tail, sitting below the icon. */
  :global(.dock-tip) {
    position: fixed;
    transform: translateX(-50%);
    z-index: 1000;
    padding: 4px 9px;
    border-radius: 7px;
    background: var(--color-fg);
    color: var(--color-page);
    font-family: var(--font-mono);
    font-size: 0.7rem;
    font-weight: 500;
    letter-spacing: 0.02em;
    white-space: nowrap;
    pointer-events: none;
    box-shadow: var(--shadow-pop);
    animation: dock-tip-in 0.12s ease-out;
  }
  :global(.dock-tip)::before {
    content: "";
    position: absolute;
    bottom: 100%;
    left: 50%;
    transform: translateX(-50%);
    border: 5px solid transparent;
    border-bottom-color: var(--color-fg);
  }
  @keyframes dock-tip-in {
    from { opacity: 0; transform: translateX(-50%) translateY(-3px); }
    to { opacity: 1; transform: translateX(-50%) translateY(0); }
  }
</style>
