<script lang="ts">
  /**
   * NetworkSwitcher — horizontal chip rail. The spine of the Network
   * surface: each chip is a destination (a virtual feed like "All" or
   * "Inbox", a specific network, or "+" to discover/create).
   *
   * Twitter-ish: the active chip carries a soft pill background; others
   * are subtle text-only until hovered. Vibe dots make networks visually
   * distinct without screaming.
   */
  import { Sparkles, Inbox as InboxIcon, Plus, Users as FriendsIcon, UsersRound as GroupsIcon, Bell as SubsIcon } from "@lucide/svelte";
  import { tick } from "svelte";

  export type Destination =
    | { kind: "all" }
    | { kind: "inbox" }
    | { kind: "friends" }
    | { kind: "groups" }
    | { kind: "subs" }
    | { kind: "network"; id: string };

  export interface ChipNetwork {
    id: string;
    name: string;
    vibeHue: number;
  }

  let {
    networks,
    active,
    inboxCount = 0,
    friendsCount = 0,
    subsUpdateCount = 0,
    onselect,
    onPlusClick,
  }: {
    networks: ChipNetwork[];
    active: Destination;
    inboxCount?: number;
    friendsCount?: number;
    subsUpdateCount?: number;
    onselect: (d: Destination) => void;
    onPlusClick: () => void;
  } = $props();

  let scroller: HTMLDivElement | null = $state(null);

  function isActive(d: Destination): boolean {
    if (active.kind !== d.kind) return false;
    if (active.kind === "network" && d.kind === "network") return active.id === d.id;
    return true;
  }

  function select(d: Destination) {
    onselect(d);
  }

  // Vibe hue from network id (matches NetworkBadge)
  function hash(s: string): number {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return Math.abs(h);
  }
</script>

<div class="rail" bind:this={scroller}>
  <button
    type="button"
    class="chip pseudo"
    class:active={isActive({ kind: "all" })}
    onclick={() => select({ kind: "all" })}
  >
    <Sparkles size={13} strokeWidth={2} />
    <span>All</span>
  </button>

  <button
    type="button"
    class="chip pseudo"
    class:active={isActive({ kind: "inbox" })}
    onclick={() => select({ kind: "inbox" })}
  >
    <InboxIcon size={13} strokeWidth={2} />
    <span>Inbox</span>
    {#if inboxCount > 0}
      <span class="count">{inboxCount}</span>
    {/if}
  </button>

  <button
    type="button"
    class="chip pseudo"
    class:active={isActive({ kind: "friends" })}
    onclick={() => select({ kind: "friends" })}
  >
    <FriendsIcon size={13} strokeWidth={2} />
    <span>Friends</span>
    {#if friendsCount > 0}
      <span class="count">{friendsCount}</span>
    {/if}
  </button>

  <button
    type="button"
    class="chip pseudo"
    class:active={isActive({ kind: "groups" })}
    onclick={() => select({ kind: "groups" })}
  >
    <GroupsIcon size={13} strokeWidth={2} />
    <span>Groups</span>
  </button>

  <button
    type="button"
    class="chip pseudo"
    class:active={isActive({ kind: "subs" })}
    onclick={() => select({ kind: "subs" })}
  >
    <SubsIcon size={13} strokeWidth={2} />
    <span>Subs</span>
    {#if subsUpdateCount > 0}
      <span class="count">{subsUpdateCount}</span>
    {/if}
  </button>

  <span class="sep" aria-hidden="true"></span>

  {#each networks as n (n.id)}
    <button
      type="button"
      class="chip"
      class:active={isActive({ kind: "network", id: n.id })}
      onclick={() => select({ kind: "network", id: n.id })}
      style:--vibe-h={hash(n.id) % 360}
    >
      <span class="dot" aria-hidden="true"></span>
      <span>{n.name}</span>
    </button>
  {/each}

  <button
    type="button"
    class="chip plus"
    onclick={() => onPlusClick()}
    aria-label="Create or join a network"
    title="Create or join a network"
  >
    <Plus size={14} strokeWidth={2.25} />
  </button>
</div>

<style>
  .rail {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    overflow-x: auto;
    scrollbar-width: none;
    -ms-overflow-style: none;
    padding: 2px;
  }
  .rail::-webkit-scrollbar { display: none; }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 30px;
    padding: 0 11px;
    border: 0;
    background: transparent;
    border-radius: 999px;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.83rem;
    font-weight: 500;
    letter-spacing: -0.005em;
    cursor: pointer;
    white-space: nowrap;
    flex: 0 0 auto;
    transition:
      color 160ms ease,
      background 200ms ease,
      transform 200ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .chip:hover { color: var(--color-fg); background: var(--color-surface-soft); }
  .chip.active {
    color: var(--color-fg);
    background: var(--color-surface-soft);
    box-shadow: inset 0 0 0 1px var(--color-border-strong);
  }

  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: hsl(var(--vibe-h) 55% 55%);
    box-shadow: 0 0 0 1.5px hsl(var(--vibe-h) 55% 55% / 0.2);
  }

  .count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 16px;
    height: 16px;
    padding: 0 5px;
    border-radius: 999px;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 0.66rem;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }

  .sep {
    width: 1px;
    height: 16px;
    background: var(--color-border);
    margin: 0 4px;
    flex: 0 0 auto;
  }

  .plus {
    padding: 0 9px;
  }
  .plus:hover { transform: translateY(-1px); }

  @media (prefers-color-scheme: dark) {
    .dot {
      background: hsl(var(--vibe-h) 60% 65%);
      box-shadow: 0 0 0 1.5px hsl(var(--vibe-h) 60% 65% / 0.24);
    }
  }
</style>
