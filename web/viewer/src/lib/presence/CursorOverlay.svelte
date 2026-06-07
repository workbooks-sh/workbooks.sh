<script lang="ts">
  import type { Peer } from "./PresenceClient";

  let { peers }: { peers: Peer[] } = $props();

  // Stale-cursor cutoff. If a peer hasn't moved in 8s, hide their
  // cursor — keeps the screen quiet when someone idles in a tab.
  const STALE_MS = 8000;
  let now = $state(Date.now());

  $effect(() => {
    const t = setInterval(() => { now = Date.now(); }, 1000);
    return () => clearInterval(t);
  });

  // A ping is "live" for 600ms after the peer clicked. Drives the
  // ripple. now ticks each second for stale-cursor cleanup; the
  // ripple uses CSS animation so it doesn't need a fast tick.
  const PING_MS = 600;

  const visible = $derived(
    peers.filter((p) => p.cursor && now - p.cursor.t < STALE_MS),
  );
</script>

<div class="overlay" aria-hidden="true">
  {#each visible as p (p.peer_id)}
    <div
      class="cursor"
      style:left={`${p.cursor!.x * 100}%`}
      style:top={`${p.cursor!.y * 100}%`}
      style:--c={p.color}
    >
      {#if p.pingAt && now - p.pingAt < PING_MS + 1000}
        {#key p.pingAt}
          <span class="ping" style:--c={p.color}></span>
        {/key}
      {/if}
      <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">
        <path d="M3 2 L3 19 L8 14 L11 21 L14 20 L11 13 L18 13 Z"
              fill="var(--c, #888)" stroke="#000" stroke-width="1" stroke-linejoin="round" />
      </svg>
      <span class="label" style:background={p.color}>{p.name}</span>
    </div>
  {/each}
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 55;
  }
  .cursor {
    position: absolute;
    transform: translate(-2px, -2px);
    transition: left 0.08s linear, top 0.08s linear;
  }
  .ping {
    position: absolute;
    left: 0; top: 0;
    width: 12px; height: 12px;
    margin: -6px 0 0 -6px;
    border-radius: 50%;
    border: 2px solid var(--c, #888);
    transform: scale(0.3);
    opacity: 0.9;
    animation: ping-ripple 600ms ease-out forwards;
    pointer-events: none;
  }
  @keyframes ping-ripple {
    0%   { transform: scale(0.3); opacity: 0.9; }
    100% { transform: scale(3.2); opacity: 0; }
  }
  .label {
    display: inline-block;
    transform: translate(14px, -4px);
    padding: 2px 6px;
    border-radius: 4px;
    color: #fff;
    font-size: 0.7rem;
    font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
    font-weight: 500;
    text-shadow: 0 1px 1px rgba(0,0,0,0.4);
    white-space: nowrap;
    box-shadow: 0 2px 6px rgba(0,0,0,0.25);
  }
</style>
