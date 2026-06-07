<script lang="ts">
  /**
   * FriendsTab — surface the friend graph (wb-u2o0.3.3).
   *
   * Three sections, all driven off /v1/network/friends:
   *   1. Pending received — accept/decline buttons
   *   2. Pending sent — read-only, "awaiting reply"
   *   3. Accepted — your actual friends, with "remove" affordance
   *
   * Top of the tab has an "add friend" type-ahead that POSTs to
   * /v1/network/friends with the entered handle.
   */
  import { onMount } from "svelte";
  import { Check, X, UserPlus, MoreHorizontal } from "@lucide/svelte";
  import { fly, slide } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import Avatar from "../components/Avatar.svelte";
  import HandleChip from "../components/HandleChip.svelte";
  import EmptyState from "../components/EmptyState.svelte";
  import {
    listFriends, requestFriend, settleFriendRequest, unfriend,
    DemoModeError, type FriendView,
  } from "../client";

  // ── State ───────────────────────────────────────────────────────
  let friends = $state<FriendView[]>([]);
  let loading = $state(true);
  let liveMode = $state(false);
  let loadError = $state<string | null>(null);

  // Add-friend input
  let addHandle = $state("");
  let adding = $state(false);
  let addBanner = $state<{ kind: "ok" | "err"; text: string } | null>(null);

  const HANDLE_RE = /^[a-z][a-z0-9_-]{0,31}$/;

  // ── Lifecycle ───────────────────────────────────────────────────
  onMount(load);

  async function load() {
    loading = true;
    loadError = null;
    try {
      const resp = await listFriends();
      friends = resp.friends;
      liveMode = true;
    } catch (e) {
      if (e instanceof DemoModeError) {
        // Sidecar unreachable — empty state (fixtures removed).
        friends = [];
        liveMode = false;
      } else {
        // Real failure — empty list + error banner with retry.
        friends = [];
        liveMode = true;
        loadError = e instanceof Error ? e.message : String(e);
      }
    } finally {
      loading = false;
    }
  }

  // ── Add friend ──────────────────────────────────────────────────
  async function submitAddFriend() {
    const h = addHandle.trim().toLowerCase().replace(/^@/, "");
    if (!h) return;
    if (!HANDLE_RE.test(h)) {
      addBanner = { kind: "err", text: "Use a–z 0–9 _ -, start with a letter." };
      return;
    }

    adding = true;
    addBanner = null;
    try {
      const result = await requestFriend(h);
      switch (result.outcome) {
        case "requested":
          addBanner = { kind: "ok", text: `Request sent to @${h}.` };
          break;
        case "auto_accepted":
          addBanner = { kind: "ok", text: `You and @${h} are now friends.` };
          break;
        case "already_friends":
          addBanner = { kind: "ok", text: `You and @${h} are already friends.` };
          break;
        case "blocked_by_target":
          // Don't leak the block — same UX as a successful request
          addBanner = { kind: "ok", text: `Request sent to @${h}.` };
          break;
      }
      addHandle = "";
      await load();
    } catch (e) {
      addBanner = { kind: "err", text: e instanceof Error ? e.message : String(e) };
    } finally {
      adding = false;
    }
  }

  function onAddKey(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      void submitAddFriend();
    }
  }

  // ── Settle pending ──────────────────────────────────────────────
  async function settle(handle: string, action: "accept" | "decline") {
    // Optimistic: drop the row immediately
    const original = friends;
    friends = friends.filter((f) => !(f.handle === handle && f.status === "pending_received"));

    try {
      if (liveMode) await settleFriendRequest(handle, action);
      await load();
    } catch (e) {
      friends = original;
      loadError = e instanceof Error ? e.message : String(e);
    }
  }

  // ── Unfriend ────────────────────────────────────────────────────
  async function remove(handle: string) {
    const original = friends;
    friends = friends.filter((f) => f.handle !== handle);
    try {
      if (liveMode) await unfriend(handle);
    } catch (e) {
      friends = original;
      loadError = e instanceof Error ? e.message : String(e);
    }
  }

  // ── Derived sections ────────────────────────────────────────────
  const pendingReceived = $derived(friends.filter((f) => f.status === "pending_received"));
  const pendingSent = $derived(friends.filter((f) => f.status === "pending_sent"));
  const accepted = $derived(friends.filter((f) => f.status === "accepted"));

  function relTime(ms: number): string {
    const dt = Date.now() - ms;
    if (dt < 60_000) return "just now";
    if (dt < 3_600_000) return `${Math.round(dt / 60_000)}m`;
    if (dt < 86_400_000) return `${Math.round(dt / 3_600_000)}h`;
    if (dt < 7 * 86_400_000) return `${Math.round(dt / 86_400_000)}d`;
    return new Date(ms).toISOString().slice(0, 10);
  }

</script>

<div class="wrap">
  <header class="head">
    <div>
      <h2>Friends</h2>
      <p class="sub">
        {accepted.length} accepted
        {#if pendingReceived.length > 0}
          · {pendingReceived.length} pending
        {/if}
        {#if liveMode}
          <span class="mode-tag live">live</span>
        {:else}
          <span class="mode-tag offline">offline</span>
        {/if}
      </p>
    </div>
  </header>

  <!-- Add friend -->
  <section class="add-card">
    <div class="add-row" class:has-text={addHandle.length > 0}>
      <span class="at">@</span>
      <input
        type="text"
        bind:value={addHandle}
        onkeydown={onAddKey}
        placeholder="handle"
        autocomplete="off"
        spellcheck={false}
        disabled={adding}
      />
      <button
        type="button"
        class="btn primary sm"
        disabled={adding || !addHandle.trim()}
        onclick={submitAddFriend}
      >
        <UserPlus size={12} strokeWidth={2.25} />
        {adding ? "Sending…" : "Send request"}
      </button>
    </div>
    {#if addBanner}
      <p class="banner {addBanner.kind}" transition:slide={{ duration: 160 }}>
        {addBanner.text}
      </p>
    {/if}
  </section>

  {#if loadError}
    <div class="banner err" transition:slide={{ duration: 180 }}>
      <div>
        <strong>Couldn't reach broker.</strong>
        <span class="banner-detail">{loadError}</span>
      </div>
      <button type="button" class="banner-retry" onclick={load}>Retry</button>
    </div>
  {/if}

  <!-- Pending received -->
  {#if pendingReceived.length > 0}
    <section>
      <h3 class="section-label">Pending — they asked you</h3>
      <div class="list">
        {#each pendingReceived as f, i (f.handle)}
          <div class="row" in:fly={{ y: 4, duration: 200, delay: i * 30, easing: cubicOut }}>
            <Avatar handle={f.handle} size="sm" />
            <div class="row-body">
              <HandleChip handle={f.handle} variant="inline" />
              <span class="ts">requested {relTime(f.created_at)}</span>
            </div>
            <button type="button" class="btn ghost sm" onclick={() => settle(f.handle, "decline")}>
              <X size={12} strokeWidth={2.25} /> Decline
            </button>
            <button type="button" class="btn primary sm" onclick={() => settle(f.handle, "accept")}>
              <Check size={12} strokeWidth={2.25} /> Accept
            </button>
          </div>
        {/each}
      </div>
    </section>
  {/if}

  <!-- Pending sent -->
  {#if pendingSent.length > 0}
    <section>
      <h3 class="section-label">Sent — awaiting reply</h3>
      <div class="list">
        {#each pendingSent as f (f.handle)}
          <div class="row">
            <Avatar handle={f.handle} size="sm" />
            <div class="row-body">
              <HandleChip handle={f.handle} variant="inline" />
              <span class="ts">sent {relTime(f.created_at)}</span>
            </div>
            <button type="button" class="btn ghost sm" onclick={() => remove(f.handle)}>
              Cancel
            </button>
          </div>
        {/each}
      </div>
    </section>
  {/if}

  <!-- Accepted friends -->
  <section>
    <h3 class="section-label">Friends</h3>
    {#if accepted.length === 0 && !loading}
      <EmptyState
        title="No friends yet"
        blurb={liveMode
          ? "Send a request to someone you trust — handles look like @alice. The Add card above takes a handle."
          : "Engine isn't reachable. Once Workhorse is running and you're connected, your friend graph shows up here."}
        glyph="✿"
        hue={340}
      />
    {:else}
      <div class="list">
        {#each accepted as f (f.handle)}
          <div class="row">
            <Avatar handle={f.handle} size="sm" />
            <div class="row-body">
              <HandleChip handle={f.handle} variant="inline" />
              <span class="ts">friends since {relTime(f.updated_at)}</span>
            </div>
            <button type="button" class="kebab" aria-label="More" onclick={() => remove(f.handle)} title="Remove friend">
              <MoreHorizontal size={14} strokeWidth={2} />
            </button>
          </div>
        {/each}
      </div>
    {/if}
  </section>
</div>

<style>
  .wrap {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    max-width: 620px;
    margin: 0 auto;
  }
  .head { display: flex; align-items: flex-end; justify-content: space-between; }
  .head h2 { margin: 0 0 .15rem; font-size: 1rem; font-weight: 600; letter-spacing: -.01em; }
  .head .sub {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .mode-tag {
    padding: 1px 6px;
    border-radius: 999px;
    font-size: 0.66rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    border: 1px solid transparent;
  }
  .mode-tag.offline {
    background: rgba(160, 100, 200, 0.10);
    border-color: rgba(160, 100, 200, 0.30);
    color: rgb(110, 70, 160);
  }
  .mode-tag.live {
    background: rgba(34, 160, 105, 0.10);
    border-color: rgba(34, 160, 105, 0.30);
    color: rgb(20, 110, 70);
  }
  .banner-detail {
    color: rgb(140, 70, 70);
    font-weight: 400;
    margin-left: 8px;
  }
  .banner-retry {
    padding: 4px 10px;
    border-radius: 5px;
    border: 1px solid rgba(220, 60, 60, 0.30);
    background: white;
    color: rgb(180, 50, 50);
    font-size: 0.74rem;
    font-weight: 600;
    cursor: pointer;
    flex-shrink: 0;
  }
  .banner-retry:hover { background: rgba(220, 60, 60, 0.08); }

  .add-card { display: flex; flex-direction: column; gap: 6px; }
  .add-row {
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: center;
    gap: 8px;
    padding: 9px 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border-strong);
    border-radius: 10px;
    transition: border-color 160ms ease, box-shadow 160ms ease, background 160ms ease;
  }
  .add-row:focus-within {
    border-color: var(--color-fg);
    background: var(--color-surface);
    box-shadow: 0 0 0 3px var(--color-ring);
  }
  .at { color: var(--color-fg-muted); font-size: 1rem; font-weight: 500; }
  .add-row input {
    background: transparent; border: 0; outline: none;
    font: inherit; font-size: 0.9rem; color: var(--color-fg); width: 100%;
  }

  .banner {
    margin: 0;
    padding: 7px 12px;
    border-radius: 6px;
    font-size: 0.78rem;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: 10px;
    justify-content: space-between;
  }
  .banner.ok {
    color: rgb(20, 110, 70);
    background: rgba(34, 160, 105, 0.08);
    border: 1px solid rgba(34, 160, 105, 0.22);
  }
  .banner.err {
    color: rgb(180, 50, 50);
    background: rgba(220, 60, 60, 0.08);
    border: 1px solid rgba(220, 60, 60, 0.22);
  }

  .section-label {
    margin: 0 0 0.45rem;
    font-size: 0.72rem;
    font-weight: 600;
    color: var(--color-fg-subtle);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .list { display: flex; flex-direction: column; gap: 0.4rem; }
  .row {
    display: grid;
    grid-template-columns: auto 1fr auto auto;
    align-items: center;
    gap: 0.65rem;
    padding: 0.55rem 0.7rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    transition: border-color 200ms ease;
  }
  .row:hover { border-color: var(--color-border-strong); }
  .row-body { display: flex; flex-direction: column; min-width: 0; gap: 1px; }
  .ts { font-size: 0.74rem; color: var(--color-fg-muted); }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    height: 28px;
    padding: 0 11px;
    border-radius: 8px;
    font: inherit;
    font-size: 0.78rem;
    font-weight: 500;
    cursor: pointer;
    transition: transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .btn.sm { height: 26px; padding: 0 10px; font-size: 0.76rem; }
  .btn:hover:not(:disabled) { transform: translateY(-1px); }
  .btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .btn.primary {
    background: var(--color-fg); color: var(--color-page); border: 1px solid var(--color-fg);
  }
  .btn.ghost {
    background: transparent; color: var(--color-fg-muted); border: 1px solid var(--color-border-strong);
  }
  .btn.ghost:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .kebab {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: 6px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    grid-column: 4;
  }
  .kebab:hover { background: var(--color-surface-soft); color: var(--color-fg); }
</style>
