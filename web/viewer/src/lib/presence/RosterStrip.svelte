<script lang="ts">
  import type { Peer } from "./PresenceClient";

  let { peers, self }: { peers: Peer[]; self: { name: string; color: string } | null } = $props();

  function initial(name: string): string {
    return name ? name[0].toUpperCase() : "?";
  }
</script>

{#if peers.length > 0 || self}
  <div class="roster" aria-label="Currently viewing">
    {#if self}
      <span class="chip self" style:--c={self.color} title={`${self.name} (you)`}>{initial(self.name)}</span>
    {/if}
    {#each peers as p (p.peer_id)}
      <span class="chip" style:--c={p.color} title={p.name}>{initial(p.name)}</span>
    {/each}
  </div>
{/if}

<style>
  .roster {
    position: fixed;
    top: 12px;
    left: 50%;
    transform: translateX(-50%);
    display: flex;
    gap: -8px;
    z-index: 60;
    pointer-events: none;
  }
  .chip {
    display: inline-grid;
    place-items: center;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: var(--c, #888);
    color: #fff;
    font-size: 0.78rem;
    font-weight: 600;
    border: 2px solid #0c0c0d;
    margin-left: -8px;
    text-shadow: 0 1px 1px rgba(0,0,0,0.4);
    box-shadow: 0 2px 6px rgba(0,0,0,0.3);
    font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
  }
  .chip.self {
    margin-left: 0;
    box-shadow: 0 0 0 2px rgba(255,255,255,0.15), 0 2px 6px rgba(0,0,0,0.3);
  }
</style>
