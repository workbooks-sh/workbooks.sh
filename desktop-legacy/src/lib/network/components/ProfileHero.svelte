<script lang="ts">
  /**
   * ProfileHero — header for a profile page. Avatar, handle, bio, stats,
   * networks-as-avatar-groups. Backdrop carries a slow-drifting personal
   * gradient derived from the avatar's iconAccent color.
   */
  import Avatar from "./Avatar.svelte";
  import NetworkBadge from "./NetworkBadge.svelte";
  import ProvenanceBadge from "./ProvenanceBadge.svelte";
  import type { Person, Network } from "../types";
  import { personalColor } from "../theme/personalColor";

  let {
    person,
    networks = [],
    isMe = false,
  }: {
    person: Person;
    /** Networks this person is in — resolved by the parent, since
     *  per-DID network lookup needs to flow through the Broker
     *  (or be Cached) rather than a local fixture. Empty by default. */
    networks?: Network[];
    isMe?: boolean;
  } = $props();

  const color = $derived(personalColor(person.handle, person.avatar));
</script>

<section class="hero">
  <div class="backdrop" style:--accent={color.ring} aria-hidden="true"></div>

  <div class="content">
    <Avatar
      handle={person.handle}
      avatar={person.avatar}
      size="xl"
      verified={person.verified}
    />

    <div class="meta">
      <div class="row top">
        <h1 class="handle">@{person.handle}</h1>
        <span class="display">{person.displayName}</span>
        {#if person.verified}
          <ProvenanceBadge
            state="verified"
            realName={person.displayName}
          />
        {/if}
      </div>
      <p class="bio">{person.bio}</p>

      <div class="stats">
        <span class="stat">
          <span class="n">{person.publishedCount}</span>
          <span class="l">published</span>
        </span>
        <span class="sep"></span>
        <span class="stat">
          <span class="n">{networks.length}</span>
          <span class="l">{networks.length === 1 ? "network" : "networks"}</span>
        </span>
        <span class="sep"></span>
        <span class="stat did" title={person.did}>
          <span class="n mono">{person.did.slice(0, 18)}…</span>
          <span class="l">DID</span>
        </span>
      </div>

      <div class="networks">
        {#each networks as n (n.id)}
          <NetworkBadge network={n} />
        {/each}
      </div>
    </div>

    <div class="actions">
      {#if isMe}
        <button type="button" class="btn ghost">Edit profile</button>
        <button type="button" class="btn primary">Share work</button>
      {:else}
        <button type="button" class="btn ghost">Message</button>
        <button type="button" class="btn primary">Follow</button>
      {/if}
    </div>
  </div>
</section>

<style>
  .hero {
    position: relative;
    border: 1px solid var(--color-border);
    border-radius: 16px;
    background: var(--color-surface);
    overflow: hidden;
  }
  .backdrop {
    position: absolute;
    inset: 0;
    height: 130px;
    background:
      radial-gradient(120% 100% at 20% 10%, var(--accent) 0%, transparent 55%),
      radial-gradient(80% 90% at 90% 20%, var(--accent) 0%, transparent 60%);
    opacity: 0.10;
    filter: blur(0px);
    animation: drift 16s ease-in-out infinite alternate;
  }
  @keyframes drift {
    from { transform: translate3d(0, 0, 0) scale(1); }
    to { transform: translate3d(-6%, -3%, 0) scale(1.08); }
  }
  .content {
    position: relative;
    display: grid;
    grid-template-columns: auto 1fr auto;
    gap: 1.2rem;
    align-items: flex-start;
    padding: 1.4rem 1.5rem 1.2rem;
  }

  .meta {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    min-width: 0;
  }
  .row {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 0.55rem;
  }
  .handle {
    margin: 0;
    font-size: 1.4rem;
    font-weight: 700;
    letter-spacing: -0.02em;
  }
  .display {
    color: var(--color-fg-muted);
    font-size: 0.92rem;
  }
  .bio {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.88rem;
    line-height: 1.55;
    max-width: 60ch;
  }

  .stats {
    display: inline-flex;
    align-items: center;
    gap: 0.7rem;
    margin-top: 0.2rem;
  }
  .stat {
    display: inline-flex;
    align-items: baseline;
    gap: 4px;
    font-size: 0.78rem;
  }
  .stat .n {
    font-weight: 700;
    font-variant-numeric: tabular-nums;
    color: var(--color-fg);
  }
  .stat .l {
    color: var(--color-fg-muted);
  }
  .stat .mono {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.74rem;
    font-weight: 500;
  }
  .stat.did { color: var(--color-fg-muted); }
  .sep {
    width: 3px;
    height: 3px;
    border-radius: 50%;
    background: var(--color-fg-subtle);
  }

  .networks {
    display: inline-flex;
    flex-wrap: wrap;
    gap: 5px;
    margin-top: 0.4rem;
  }

  .actions {
    display: inline-flex;
    flex-direction: column;
    gap: 6px;
    align-self: flex-start;
  }
  .btn {
    height: 30px;
    padding: 0 12px;
    border-radius: 8px;
    font: inherit;
    font-size: 0.8rem;
    font-weight: 500;
    cursor: pointer;
    transition: transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1), background 160ms ease;
  }
  .btn:hover { transform: translateY(-1px); }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
    border: 1px solid var(--color-fg);
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg);
    border: 1px solid var(--color-border-strong);
  }
  .btn.ghost:hover { background: var(--color-surface-soft); }
</style>
