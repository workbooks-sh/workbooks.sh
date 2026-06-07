<script lang="ts">
  /**
   * NetworkPanel — top-level Network surface for Workbooks Desktop.
   *
   * Nav model: networks-as-tabs. The top strip is a chip rail of:
   *   [All] [Inbox N] | <each of your networks> | [+]
   * Profile + Settings + Sign-out live in the avatar dropdown on the
   * right. [+] opens JoinOrCreateModal (no public discover surface — by
   * design; the network is invite-only).
   */
  import NetworkSwitcher, {
    type Destination,
    type ChipNetwork,
  } from "./components/NetworkSwitcher.svelte";
  import AvatarMenu from "./components/AvatarMenu.svelte";
  import JoinOrCreateModal from "./components/JoinOrCreateModal.svelte";
  import PostComposer from "./components/PostComposer.svelte";
  import ConnectFlow from "./components/ConnectFlow.svelte";
  import FeedTab from "./tabs/FeedTab.svelte";
  import GetStarted from "./GetStarted.svelte";
  import ProfileTab from "./tabs/ProfileTab.svelte";
  import InboxTab from "./tabs/InboxTab.svelte";
  import SettingsTab from "./tabs/SettingsTab.svelte";
  import FriendsTab from "./tabs/FriendsTab.svelte";
  import GroupsTab from "./tabs/GroupsTab.svelte";
  import SubscriptionsTab from "./tabs/SubscriptionsTab.svelte";
  import { auth } from "$lib/auth/store.svelte";
  import EmptyState from "./components/EmptyState.svelte";
  import { LogIn } from "@lucide/svelte";

  // Chip-rail counts. Real counts are surfaced inside each tab's
  // header; the chip-rail badges sit at zero until a cross-tab event
  // bus pipes them up (follow-up).
  const pendingInbox = 0;
  let pendingFriends = $state(0);
  let subsUpdates = $state(0);

  // The app-level auth store has already gated sidecar + sign-in by
  // the time this panel mounts. Whether the user has BOUND a Network
  // identity (handle + DID via Workhorse) is a panel-specific concern —
  // we read it from auth.identity, which the store hydrates at boot.
  const myHandle = $derived(auth.identity?.handle ?? null);
  const bound = $derived(!!auth.identity);

  // Networks-as-tabs surfaces the user's joined networks as chips.
  // The "networks" concept has no Broker-side endpoint yet, so the
  // list is empty in production — the chip rail shows just All +
  // Inbox + Friends + Groups + Subs + [+].
  const myNetworks: ChipNetwork[] = [];

  // Active view. Profile + Settings are reachable only via the avatar
  // menu, not via the chip rail — so they live in a wider union.
  type View = Destination | { kind: "profile" } | { kind: "settings" };
  let active = $state<View>({ kind: "all" });

  // [+] modal overlay state — independent of `active` so the underlying
  // view stays put behind the dialog.
  let joinCreateOpen = $state(false);
  let composerOpen = $state(false);
  let connectOpen = $state(false);

  // If composer opens while you're inside a specific network, default
  // that network as the post target.
  const composerNetwork = $derived(
    active.kind === "network" ? active.id : null,
  );

  function onNavigate(target: "profile" | "settings") {
    active = { kind: target };
  }

  // The chip rail wants a Destination, not the wider View. When we're
  // viewing Profile/Settings, surface "All" as the visually active chip
  // (no chip lights up for the overlay views).
  const chipActive = $derived<Destination>(
    active.kind === "profile" || active.kind === "settings"
      ? { kind: "all" }
      : active,
  );
</script>

<section class="panel">
  <!-- The chip rail (All/Inbox/Friends/Groups/Subs/+) is only
       meaningful once the user has a bound Network identity. On the
       GetStarted landing for not-yet-bound users, none of the chips
       have anywhere to navigate to — hide the whole bar so the page
       reads as a clean introduction rather than a configured-but-
       empty surface. -->
  {#if !(active.kind === "all" && auth.status === "signed-in" && !bound)}
  <header class="bar">
    <div class="bar-inner">
      <div class="left">
        <NetworkSwitcher
          networks={myNetworks}
          active={chipActive}
          inboxCount={pendingInbox}
          friendsCount={pendingFriends}
          subsUpdateCount={subsUpdates}
          onselect={(d) => (active = d)}
          onPlusClick={() => (joinCreateOpen = true)}
        />
      </div>
      <div class="right">
        {#if bound}
          <button
            type="button"
            class="post-btn"
            onclick={() => (composerOpen = true)}
            title={myHandle ? `Posting as @${myHandle}` : ""}
          >
            Post
          </button>
        {:else}
          <button
            type="button"
            class="post-btn"
            onclick={() => (connectOpen = true)}
          >
            Connect
          </button>
        {/if}
        <AvatarMenu handle={myHandle} onnavigate={onNavigate} />
      </div>
    </div>
  </header>
  {/if}

  <!-- The "All" landing is the get-started page, which renders its
       own background orbs that need to reach the panel edges. Drop
       the standard inset padding for that view; every other tab
       keeps the cozy 1.4rem/2rem gutter. -->
  <div class="content" class:fullbleed={active.kind === "all" && auth.status !== "signed-out"}>
    {#if auth.status === "signed-out"}
      <!-- Network features need a signed-in account. App-wide stays
           anonymous; this gate covers just this panel. -->
      <EmptyState
        title="Sign in to use the network"
        blurb="The network lets you share workbooks with friends, follow publishers, and join groups. Everything else in Workbooks works without an account — sign in only if you want this surface."
        glyph="✦"
        hue={190}
      >
        {#snippet cta()}
          <button
            type="button"
            class="signin-cta"
            onclick={() => auth.signIn()}
          >
            <LogIn size={13} strokeWidth={2.25} />
            Sign in to Workbooks
          </button>
        {/snippet}
      </EmptyState>
    {:else if active.kind === "all"}
      <!-- "All" is the network front door. Until there's an actual
           cross-network feed endpoint AND the user has built up some
           activity, show the get-started page instead of an empty
           feed — the user asked for a proper value-prop landing here,
           not a sad "no items" state. -->
      <GetStarted
        {bound}
        onconnect={() => (connectOpen = true)}
        oncreate={() => (joinCreateOpen = true)}
      />
    {:else if active.kind === "network"}
      <FeedTab networkId={active.id} />
    {:else if active.kind === "inbox"}
      <InboxTab />
    {:else if active.kind === "friends"}
      <FriendsTab />
    {:else if active.kind === "groups"}
      <GroupsTab />
    {:else if active.kind === "subs"}
      <SubscriptionsTab />
    {:else if active.kind === "profile"}
      <ProfileTab />
    {:else if active.kind === "settings"}
      <SettingsTab />
    {/if}
  </div>

  {#if joinCreateOpen}
    <JoinOrCreateModal onclose={() => (joinCreateOpen = false)} />
  {/if}

  {#if composerOpen}
    <PostComposer
      initialNetworkId={composerNetwork}
      onclose={() => (composerOpen = false)}
    />
  {/if}

  {#if connectOpen}
    <ConnectFlow
      onclose={() => (connectOpen = false)}
      onconnected={() => {
        // ConnectFlow has bound the identity through Workhorse.
        // Re-probe the auth store so auth.identity hydrates with the
        // new binding; the bar's Post/Connect toggle is derived from
        // it, so the UI updates automatically.
        void auth.refresh();
        connectOpen = false;
      }}
    />
  {/if}
</section>

<style>
  .panel {
    flex: 1 1 auto;
    overflow: auto;
    display: flex;
    flex-direction: column;
    background: var(--color-page);
  }
  .bar {
    position: sticky;
    top: 0;
    z-index: 5;
    background: color-mix(in srgb, var(--color-page) 92%, transparent);
    backdrop-filter: blur(10px);
    border-bottom: 1px solid var(--color-border);
  }
  .bar-inner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.7rem 1.5rem;
    max-width: 1200px;
    margin: 0 auto;
  }
  .left { min-width: 0; flex: 1; }
  .right {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    gap: 0.7rem;
  }

  .post-btn {
    height: 32px;
    padding: 0 16px;
    border-radius: 999px;
    background: var(--color-fg);
    color: var(--color-page);
    border: 1px solid var(--color-fg);
    font: inherit;
    font-size: 0.84rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    cursor: pointer;
    transition:
      transform 180ms cubic-bezier(0.22, 1.2, 0.36, 1),
      box-shadow 200ms ease;
  }
  .post-btn:hover {
    transform: translateY(-1px);
    box-shadow: 0 6px 16px rgba(15, 15, 15, 0.12);
  }
  .post-btn:active { transform: translateY(0); }

  .content {
    flex: 1;
    padding: 1.4rem 2rem 3rem;
    overflow-x: hidden;
  }
  .content.fullbleed {
    padding: 0;
  }

  .signin-cta {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 9px 18px;
    border-radius: 8px;
    background: var(--color-fg);
    color: var(--color-page);
    border: 1px solid var(--color-fg);
    font: inherit;
    font-size: 0.86rem;
    font-weight: 600;
    cursor: pointer;
    transition:
      transform 180ms cubic-bezier(0.22, 1.2, 0.36, 1),
      box-shadow 200ms ease;
  }
  .signin-cta:hover {
    transform: translateY(-1px);
    box-shadow: 0 6px 16px rgba(15, 15, 15, 0.12);
  }
</style>
