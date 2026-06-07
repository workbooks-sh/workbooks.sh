<script lang="ts">
  /**
   * Share drawer (wb-v9ys.3).
   *
   * Renders the per-workbook share state and the small surface a user
   * needs to mint a room, copy the URL, toggle on/off, and push a
   * release. The drawer is the entire feature surface for Live URLs
   * on the desktop side; later slices (password, comments, presence)
   * grow sections inside it without changing the outer shape.
   */
  import { shareStore } from "$lib/share/store.svelte";
  import { liveUrlFor, type RoomAccessMode } from "$lib/share/client";
  import { toasts } from "$lib/bridge/toasts.svelte";

  let { path, onclose }: { path: string; onclose: () => void } = $props();

  // Don't name this `state` — collides with the `$state` rune token in
  // Svelte 5 and svelte-check trips over the shadowing (same as
  // ShareButton.svelte).
  const share = $derived(shareStore.get(path));

  // Password panel state — opens inline under the access row when the
  // user picks the Password pill (or wants to rotate). Stays local to
  // the drawer so a stray close doesn't lose it.
  let pwOpen = $state(false);
  let pwInput = $state("");

  // Comments — load on first open of a primary room, poll every 15s
  // while the drawer is open. WS push lands in slice 6.
  let commentsTab = $state<"open" | "unresolved" | "resolved">("open");

  // For slice 3 we only surface one room per workbook in the UI
  // (the broker schema supports N for slice ?). Pick the most-recent
  // one if there are multiples.
  const primaryRoom = $derived(
    share.rooms.length === 0
      ? null
      : [...share.rooms].sort((a, b) => b.created_at - a.created_at)[0],
  );

  const liveUrl = $derived(primaryRoom ? liveUrlFor(primaryRoom.slug) : null);

  const slugComments = $derived(
    primaryRoom ? share.comments[primaryRoom.slug] ?? null : null,
  );
  const openComments = $derived(
    (slugComments ?? []).filter((c) => c.resolved_at == null && c.anchor_resolved),
  );
  const unresolvedComments = $derived(
    (slugComments ?? []).filter((c) => !c.anchor_resolved && c.resolved_at == null),
  );
  const resolvedComments = $derived(
    (slugComments ?? []).filter((c) => c.resolved_at != null),
  );
  const visibleComments = $derived(
    commentsTab === "open" ? openComments
    : commentsTab === "unresolved" ? unresolvedComments
    : resolvedComments,
  );

  $effect(() => {
    if (!primaryRoom) return;
    if (slugComments === null) {
      void shareStore.loadComments(path, primaryRoom.slug);
    }
  });

  // Pull the account's tier + quota readback on drawer mount.
  $effect(() => {
    void shareStore.loadTier();
  });
  const tier = $derived(shareStore.tier);
  const tierLabel = $derived(
    tier ? (tier.limits.tier === "free" ? "Free plan" : `${tier.limits.tier} plan`) : null,
  );
  const quotaUsage = $derived(
    tier && tier.limits.max_enabled_rooms != null
      ? `${tier.enabled_rooms_used} of ${tier.limits.max_enabled_rooms} active`
      : null,
  );

  // Subscribe to the room WS while the drawer is open. Live comments
  // + roster replace the 15s polling from slice 5.
  $effect(() => {
    if (!primaryRoom) return;
    const slug = primaryRoom.slug;
    shareStore.subscribe(path, slug);
    return () => shareStore.unsubscribe(slug);
  });

  const livePeers = $derived(primaryRoom ? share.peers[primaryRoom.slug] ?? [] : []);

  function fmtAge(unixSec: number): string {
    const delta = Math.floor(Date.now() / 1000) - unixSec;
    if (delta < 60) return `${delta}s ago`;
    if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
    if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
    return `${Math.floor(delta / 86400)}d ago`;
  }

  async function onResolveComment(id: string, resolved: boolean) {
    if (!primaryRoom) return;
    try {
      await shareStore.toggleCommentResolved(path, primaryRoom.slug, id, resolved);
    } catch {
      toasts.push({ kind: "error", message: "Couldn't update comment" });
    }
  }

  async function onDeleteComment(id: string) {
    if (!primaryRoom) return;
    try {
      await shareStore.removeComment(path, primaryRoom.slug, id);
    } catch {
      toasts.push({ kind: "error", message: "Couldn't delete comment" });
    }
  }

  async function onCreate() {
    try {
      const room = await shareStore.createFirstRoom(path);
      toasts.push({ kind: "success", message: `Live URL created — ${liveUrlFor(room.slug)}` });
    } catch (err) {
      // Demo-mode is shown inline via share.status === "demo"; only
      // surface unexpected errors via toast.
      if (share.status !== "demo") {
        toasts.push({ kind: "error", message: `Couldn't create: ${share.error ?? "see console"}` });
      }
    }
  }

  async function onRelease() {
    if (!primaryRoom) return;
    try {
      await shareStore.release(path);
      toasts.push({ kind: "success", message: "Released new version" });
    } catch {
      toasts.push({ kind: "error", message: `Couldn't release: ${share.error ?? "see console"}` });
    }
  }

  async function onToggle(checked: boolean) {
    if (!primaryRoom) return;
    try {
      await shareStore.toggleEnabled(path, primaryRoom.slug, checked);
    } catch {
      toasts.push({ kind: "error", message: `Couldn't toggle: ${share.error ?? "see console"}` });
    }
  }

  async function onCopy() {
    if (!liveUrl) return;
    try {
      await navigator.clipboard.writeText(liveUrl);
      toasts.push({ kind: "success", message: "URL copied" });
    } catch {
      toasts.push({ kind: "error", message: "Couldn't copy" });
    }
  }

  async function setAccess(mode: RoomAccessMode, password?: string) {
    if (!primaryRoom) return;
    try {
      await shareStore.setAccess(path, primaryRoom.slug, {
        access_mode: mode,
        password,
      });
      toasts.push({
        kind: "success",
        message: mode === "password" ? "Password set" : "Switched to link access",
      });
      pwOpen = false;
      pwInput = "";
    } catch {
      toasts.push({ kind: "error", message: `Couldn't change access: ${share.error ?? "see console"}` });
    }
  }

  function onPasswordSubmit(e: Event) {
    e.preventDefault();
    if (pwInput.length < 4) {
      toasts.push({ kind: "error", message: "Password needs at least 4 characters" });
      return;
    }
    void setAccess("password", pwInput);
  }
</script>

<button class="scrim" aria-label="Close share drawer" onclick={onclose}></button>

<aside class="drawer" aria-label="Share">
  <header>
    <h2>Share</h2>
    {#if tierLabel}
      <span class="tier" title={quotaUsage ?? ""}>
        {tierLabel}{#if quotaUsage} · {quotaUsage}{/if}
      </span>
    {/if}
    <button class="close" onclick={onclose} aria-label="Close">×</button>
  </header>

  <div class="body">
    {#if share.status === "demo"}
      <div class="row notice">
        <div class="title">Sign in to share</div>
        <p>Live URLs need a Workbooks account to publish. Sign in from the rail and the share flow turns on.</p>
      </div>

    {:else if share.status === "unknown"}
      <div class="row muted">Checking share state…</div>

    {:else if share.status === "unshared"}
      <div class="row">
        <div class="title">This workbook isn't shared yet</div>
        <p>Create a live URL to send to anyone. Updates publish on release; recipients always see the current version.</p>
        <button class="primary" onclick={onCreate}>Create live URL</button>
      </div>

    {:else if share.status === "sharing"}
      <div class="row muted">Working…</div>

    {:else if share.status === "shared" && primaryRoom && liveUrl}
      <div class="row">
        <div class="title">Live URL</div>
        <div class="url-row">
          <input class="url" readonly value={liveUrl} />
          <button class="copy" onclick={onCopy}>Copy</button>
        </div>
        <p class="hint">
          {#if primaryRoom.enabled}
            Recipients can open this URL right now.
          {:else}
            Paused — recipients see a 410 until you turn it back on.
          {/if}
        </p>
      </div>

      <div class="row">
        <label class="toggle">
          <input
            type="checkbox"
            checked={primaryRoom.enabled}
            onchange={(e) => onToggle((e.currentTarget as HTMLInputElement).checked)}
          />
          <span>Enabled</span>
        </label>
      </div>

      <div class="row">
        <div class="title">Access</div>
        <div class="access">
          <button
            type="button"
            class="pill"
            class:active={primaryRoom.access_mode === "link"}
            onclick={() => setAccess("link")}
          >Link only</button>
          <button
            type="button"
            class="pill"
            class:active={primaryRoom.access_mode === "password"}
            class:disabled={tier ? !tier.limits.can_password : false}
            disabled={tier ? !tier.limits.can_password : false}
            title={tier && !tier.limits.can_password ? "Password access requires Pro" : ""}
            onclick={() => { pwOpen = true; pwInput = ""; }}
          >{primaryRoom.access_mode === "password" ? (primaryRoom.has_password ? "Password ●" : "Password") : "Password"}</button>
          <span class="pill disabled" title="Coming with Network">Workbooks account</span>
        </div>
        {#if pwOpen || (primaryRoom.access_mode === "password" && !primaryRoom.has_password)}
          <form class="pw-form" onsubmit={onPasswordSubmit}>
            <input
              type="password"
              placeholder={primaryRoom.access_mode === "password" ? "New password (rotates)" : "Set a password"}
              bind:value={pwInput}
              autocomplete="new-password"
              minlength="4"
            />
            <div class="pw-actions">
              <button type="submit" class="primary small">
                {primaryRoom.access_mode === "password" ? "Rotate" : "Set password"}
              </button>
              <button type="button" class="ghost small" onclick={() => { pwOpen = false; pwInput = ""; }}>Cancel</button>
            </div>
          </form>
        {/if}
      </div>

      <div class="row">
        <button class="primary" onclick={onRelease}>Release new version</button>
        <p class="hint">Uploads the current .html to all enabled rooms.</p>
      </div>

      <div class="row">
        <div class="title">
          Watching now
          <span class="peer-count">{livePeers.length}</span>
        </div>
        {#if livePeers.length === 0}
          <p class="hint">No one is viewing right now. Share the URL to see live cursors here.</p>
        {:else}
          <ul class="peers">
            {#each livePeers as p (p.peer_id)}
              <li class="peer">
                <span class="peer-dot" style:background={p.color}></span>
                <span class="peer-name">{p.name}</span>
              </li>
            {/each}
          </ul>
        {/if}
      </div>

      <div class="row">
        <div class="title comments-title">
          <span>Comments</span>
          <span class="counts">
            <button
              type="button"
              class="tab"
              class:active={commentsTab === "open"}
              onclick={() => (commentsTab = "open")}
            >{openComments.length} open</button>
            <button
              type="button"
              class="tab"
              class:active={commentsTab === "unresolved"}
              onclick={() => (commentsTab = "unresolved")}
            >{unresolvedComments.length} stranded</button>
            <button
              type="button"
              class="tab"
              class:active={commentsTab === "resolved"}
              onclick={() => (commentsTab = "resolved")}
            >{resolvedComments.length} done</button>
          </span>
        </div>

        {#if slugComments === null}
          <p class="hint">Loading comments…</p>
        {:else if visibleComments.length === 0}
          <p class="hint">
            {#if commentsTab === "open"}No open comments. Recipients can leave notes from the runner.{/if}
            {#if commentsTab === "unresolved"}Nothing stranded. (A comment lands here when a release removes the cell it was anchored to.){/if}
            {#if commentsTab === "resolved"}Nothing marked done yet.{/if}
          </p>
        {:else}
          <ul class="comments">
            {#each visibleComments as c (c.id)}
              <li class="comment">
                <div class="comment-head">
                  <span class="who" style:--who={c.author_color}>{c.author_name}</span>
                  <span class="when">{fmtAge(c.created_at)}</span>
                </div>
                {#if c.anchor_kind === "cell"}
                  <div class="anchor">cell · <code>{c.anchor_target}</code>{#if !c.anchor_resolved} · <span class="stranded-tag">stranded</span>{/if}</div>
                {:else if c.anchor_kind === "region"}
                  <div class="anchor">region</div>
                {/if}
                <div class="body">{c.body}</div>
                <div class="comment-actions">
                  {#if c.resolved_at == null}
                    <button class="ghost small" onclick={() => onResolveComment(c.id, true)}>Mark done</button>
                  {:else}
                    <button class="ghost small" onclick={() => onResolveComment(c.id, false)}>Re-open</button>
                  {/if}
                  <button class="ghost small danger" onclick={() => onDeleteComment(c.id)}>Delete</button>
                </div>
              </li>
            {/each}
          </ul>
        {/if}
      </div>

    {:else if share.status === "error"}
      <div class="row error">
        <div class="title">Something went wrong</div>
        <p>{share.error}</p>
      </div>
    {/if}
  </div>
</aside>

<style>
  .scrim {
    position: fixed; inset: 0;
    background: rgba(0,0,0,0.4);
    border: 0; cursor: pointer;
    z-index: 90;
  }
  .drawer {
    position: fixed; top: 0; right: 0; bottom: 0;
    width: 380px; max-width: 100vw;
    background: var(--color-surface);
    border-left: 1px solid var(--color-border);
    display: flex; flex-direction: column;
    z-index: 91;
    box-shadow: -8px 0 24px rgba(0,0,0,0.15);
  }
  header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 14px 16px;
    border-bottom: 1px solid var(--color-border);
  }
  h2 { margin: 0; font-size: 0.95rem; font-weight: 600; }
  .tier {
    margin-left: 10px;
    font-size: 0.7rem;
    padding: 2px 8px;
    border-radius: 999px;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
  }
  .close {
    background: transparent; border: 0; cursor: pointer;
    font-size: 1.25rem; color: var(--color-fg-muted);
    padding: 0 4px; line-height: 1;
  }
  .close:hover { color: var(--color-fg); }
  .body { padding: 12px; display: flex; flex-direction: column; gap: 16px; overflow-y: auto; }
  .row {
    display: flex; flex-direction: column; gap: 6px;
  }
  .row.muted { color: var(--color-fg-muted); font-size: 0.85rem; }
  .row.notice {
    padding: 12px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-surface-soft);
  }
  .row.error {
    padding: 10px 12px;
    border: 1px solid #ef4444;
    border-radius: 8px;
    color: #ef4444;
  }
  .title { font-size: 0.8rem; font-weight: 600; }
  p { margin: 0; font-size: 0.8rem; color: var(--color-fg-muted); line-height: 1.45; }
  .hint { font-size: 0.72rem; }

  .url-row { display: flex; gap: 6px; }
  .url {
    flex: 1 1 auto;
    padding: 6px 8px;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    background: var(--color-page);
    color: var(--color-fg);
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.78rem;
  }
  .copy {
    padding: 6px 10px;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    background: var(--color-surface);
    color: var(--color-fg);
    cursor: pointer;
    font-size: 0.78rem;
  }
  .copy:hover { background: var(--color-surface-soft); }

  .toggle { display: inline-flex; align-items: center; gap: 8px; font-size: 0.85rem; }
  .toggle input { margin: 0; }

  .access { display: flex; gap: 6px; flex-wrap: wrap; }
  .pill {
    padding: 3px 8px;
    border-radius: 999px;
    font-size: 0.72rem;
    border: 1px solid var(--color-border);
  }
  button.pill {
    background: var(--color-surface);
    color: var(--color-fg);
    cursor: pointer;
    font: inherit;
  }
  button.pill:hover { background: var(--color-surface-soft); }
  .pill.active { background: var(--color-fg); color: var(--color-page); border-color: var(--color-fg); }
  .pill.disabled { color: var(--color-fg-muted); cursor: not-allowed; opacity: 0.55; }
  button.pill:disabled { cursor: not-allowed; opacity: 0.55; }
  .pw-form {
    margin-top: 6px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .pw-form input {
    padding: 6px 8px;
    border-radius: 6px;
    border: 1px solid var(--color-border);
    background: var(--color-page);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.8rem;
  }
  .pw-actions { display: flex; gap: 6px; }
  .small { font-size: 0.78rem; padding: 5px 10px; }
  .ghost {
    border-radius: 6px;
    border: 1px solid var(--color-border);
    background: transparent;
    color: var(--color-fg);
    cursor: pointer;
  }
  .ghost:hover { background: var(--color-surface-soft); }
  .ghost.danger { color: #ef4444; }

  /* Comments */
  .comments-title {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
  }
  .counts { display: flex; gap: 4px; }
  .tab {
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
    border-radius: 999px;
    font-size: 0.7rem;
    padding: 2px 8px;
    cursor: pointer;
  }
  .tab:hover { color: var(--color-fg); }
  .tab.active { background: var(--color-fg); color: var(--color-page); border-color: var(--color-fg); }
  .comments {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .comment {
    padding: 10px 12px;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
  }
  .comment-head {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.78rem;
  }
  .who {
    font-weight: 600;
    color: var(--who);
  }
  .when { color: var(--color-fg-muted); }
  .anchor {
    margin-top: 2px;
    font-size: 0.7rem;
    color: var(--color-fg-muted);
  }
  .anchor code {
    font-family: ui-monospace, SF Mono, Menlo, monospace;
    background: var(--color-page);
    padding: 1px 5px;
    border-radius: 4px;
  }
  .stranded-tag {
    color: #f59e0b;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    font-weight: 600;
  }
  .comment .body {
    margin-top: 6px;
    font-size: 0.85rem;
    color: var(--color-fg);
    white-space: pre-wrap;
    word-break: break-word;
  }
  .comment-actions {
    margin-top: 8px;
    display: flex;
    gap: 6px;
  }
  .peer-count {
    margin-left: 6px;
    padding: 1px 6px;
    border-radius: 999px;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    font-size: 0.7rem;
    font-weight: 500;
  }
  .peers {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .peer {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 8px;
    border-radius: 6px;
    background: var(--color-surface-soft);
    font-size: 0.82rem;
  }
  .peer-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex: 0 0 auto;
  }
  .peer-name {
    color: var(--color-fg);
  }

  .primary {
    padding: 7px 12px;
    border-radius: 6px;
    border: 1px solid var(--color-fg);
    background: var(--color-fg);
    color: var(--color-page);
    cursor: pointer;
    font-size: 0.82rem;
    font-weight: 500;
    align-self: flex-start;
  }
  .primary:hover { opacity: 0.92; }
  .primary:disabled { opacity: 0.6; cursor: default; }
</style>
