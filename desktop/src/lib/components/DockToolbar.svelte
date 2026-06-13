<script lang="ts">
  /**
   * DockToolbar (wb-aakl.14) — the top-right toolbar in the titlebar.
   *
   * One button per registered dock panel; clicking toggles that panel in
   * the right dock. The engine status chip stays separate (it sits beside
   * this). Empty until something registers — the shipped browser registers
   * the agent panel only when WB_FF_AGENTS is on; toolkits (Browser SDK,
   * wb-aakl.15) register here too.
   */
  import { dock } from "$lib/bridge/dock.svelte";
</script>

{#each dock.panels as p (p.id)}
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
  .dock-btn.icon-only {
    padding: 0 9px;
    color: var(--color-fg);
  }
  .dock-btn {
    display: inline-flex;
    align-items: center;
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
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }
  .dock-btn:hover {
    background: color-mix(in srgb, var(--color-fg) 6%, transparent);
    color: var(--color-fg);
  }
  .dock-btn.active {
    background: var(--color-fg);
    color: var(--color-page);
  }
</style>
