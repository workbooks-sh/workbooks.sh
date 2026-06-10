<script lang="ts">
  /**
   * NetworkBadge — small pill showing a network's name, member count,
   * and visibility icon. Subtle gradient backdrop derived from the
   * network's "vibe" (a deterministic hash of the id) for restrained
   * personal-color flair without overpowering the monochrome chrome.
   */
  import { Users, Lock, Key as KeyRound, Globe } from "phosphor-svelte";
  import type { Network } from "../types";

  let {
    network,
    showCount = true,
    onclick,
  }: {
    network: Network;
    showCount?: boolean;
    onclick?: () => void;
  } = $props();

  // Deterministic hue per network id. Same network always reads the same.
  function hash(s: string): number {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return Math.abs(h);
  }
  const hue = $derived(hash(network.id) % 360);
  const JoinIcon = $derived(
    network.join === "open" ? Globe : network.join === "request" ? KeyRound : Lock,
  );
  const joinLabel = $derived(
    network.join === "open" ? "Open" : network.join === "request" ? "Request" : "Invite-only",
  );
</script>

<button
  type="button"
  class="badge"
  style:--vibe-h="{hue}"
  title={joinLabel}
  {onclick}
>
  <span class="dot" aria-hidden="true"></span>
  <span class="name">{network.name}</span>
  {#if showCount}
    <span class="sep">·</span>
    <Users weight="fill" size={11} />
    <span class="count">{network.memberCount}</span>
  {/if}
  <JoinIcon size={11} weight="fill" class="join-icon" />
</button>

<style>
  .badge {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 9px 4px 7px;
    border-radius: 999px;
    background:
      linear-gradient(
        130deg,
        hsl(var(--vibe-h) 60% 92% / 0.7),
        hsl(calc(var(--vibe-h) + 40) 60% 96% / 0.5)
      ),
      var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.74rem;
    font-weight: 500;
    cursor: pointer;
    transition:
      transform 200ms cubic-bezier(0.22, 1.2, 0.36, 1),
      border-color 200ms ease,
      box-shadow 200ms ease;
  }
  .badge:hover {
    transform: translateY(-1px);
    border-color: var(--color-border-strong);
    box-shadow: 0 2px 6px rgba(15, 15, 15, 0.04);
  }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: hsl(var(--vibe-h) 55% 50%);
    box-shadow: 0 0 0 1.5px hsl(var(--vibe-h) 55% 50% / 0.18);
    flex: 0 0 auto;
  }
  .name {
    letter-spacing: -0.01em;
  }
  .sep {
    color: var(--color-fg-subtle);
  }
  .count {
    color: var(--color-fg-muted);
    font-variant-numeric: tabular-nums;
    font-weight: 600;
  }
  :global(.join-icon) {
    color: var(--color-fg-subtle);
    margin-left: 2px;
  }

  @media (prefers-color-scheme: dark) {
    .badge {
      background:
        linear-gradient(
          130deg,
          hsl(var(--vibe-h) 40% 22% / 0.55),
          hsl(calc(var(--vibe-h) + 40) 40% 18% / 0.35)
        ),
        var(--color-surface);
    }
    .dot {
      background: hsl(var(--vibe-h) 60% 65%);
      box-shadow: 0 0 0 1.5px hsl(var(--vibe-h) 60% 65% / 0.22);
    }
  }
</style>
