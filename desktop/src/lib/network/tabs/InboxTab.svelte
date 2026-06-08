<script lang="ts">
  /**
   * InboxTab — targeted shares (direct, person-to-person).
   *
   * Calls Broker GET /v1/network/inbox in live mode; falls back to
   * fixture data in demo mode (or when the broker isn't reachable),
   * so the design surface keeps rendering during dev. Accept/decline
   * hit POST /v1/network/shares/:id/{accept,decline} in live mode.
   */
  import { onMount } from "svelte";
  import { Check, X } from "@lucide/svelte";
  import { fly, slide } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import Avatar from "../components/Avatar.svelte";
  import HandleChip from "../components/HandleChip.svelte";
  import ShareCard from "../components/ShareCard.svelte";
  import PreviewPane from "../components/PreviewPane.svelte";
  import EmptyState from "../components/EmptyState.svelte";
  import type { Artifact, Share } from "../types";
  import {
    getInbox,
    settleShare,
    DemoModeError,
    type InboxShareView,
  } from "../client";

  let items = $state<Share[]>([]);
  let preview = $state<Artifact | null>(null);
  let liveMode = $state(false);
  let loadError = $state<string | null>(null);
  let loading = $state(true);

  onMount(load);

  async function load() {
    loading = true;
    loadError = null;
    try {
      const resp = await getInbox();
      // Map Broker shape → the display shape this tab renders. Future
      // task: also fetch the workbook content from Radicle to populate
      // real title/blurb/snapshot — for v1 we synthesize placeholders
      // from the rid + artifact_kind.
      items = resp.pending.map(toDisplayShape);
      liveMode = true;
    } catch (e) {
      if (e instanceof DemoModeError) {
        // Sidecar unreachable (running in pure web/dev preview). Show
        // empty state — fixture data was removed because the audit
        // flagged it as leaking into production UI surfaces.
        items = [];
        liveMode = false;
      } else {
        // Real failure: empty list + banner with retry.
        items = [];
        liveMode = true;
        loadError = e instanceof Error ? e.message : String(e);
      }
    } finally {
      loading = false;
    }
  }

  function toDisplayShape(s: InboxShareView): Share {
    const emojiByKind: Record<InboxShareView["artifact_kind"], string> = {
      workbook: "📄",
      agent: "🤖",
      plugin: "🧩",
      skill: "🎯",
    };
    return {
      id: s.id,
      from: s.from_handle,
      to: "me",
      artifact: {
        id: s.rid,
        kind: s.artifact_kind,
        title: deriveTitleFromRid(s.rid),
        blurb: s.message ?? `${s.artifact_kind} from @${s.from_handle}`,
        authorHandle: s.from_handle,
        thumbnailEmoji: emojiByKind[s.artifact_kind],
        verified: s.from_did != null,
      },
      message: s.message ?? undefined,
      state: "pending",
      ts: relativeTime(s.created_at),
    };
  }

  function deriveTitleFromRid(rid: string): string {
    // Until we can pull the workbook's actual title from Radicle, use
    // a short identifier so the row reads. `rad:z3HhM…BgAKd`.
    const trimmed = rid.replace(/^rad:/, "");
    return `rad:${trimmed.slice(0, 6)}…${trimmed.slice(-4)}`;
  }

  function relativeTime(ts_ms: number): string {
    const dt = Date.now() - ts_ms;
    if (dt < 60_000) return "just now";
    if (dt < 3_600_000) return `${Math.round(dt / 60_000)}m`;
    if (dt < 86_400_000) return `${Math.round(dt / 3_600_000)}h`;
    if (dt < 7 * 86_400_000) return `${Math.round(dt / 86_400_000)}d`;
    return new Date(ts_ms).toISOString().slice(0, 10);
  }

  async function settle(id: string, state: Share["state"]) {
    // Optimistic UI — update locally first, retry on server failure.
    items = items.map((s) => (s.id === id ? { ...s, state } : s));

    if (liveMode) {
      const action = state === "accepted" ? "accept" : "decline";
      try {
        await settleShare(id, action);
      } catch (e) {
        // Roll back optimistic update if the server rejected
        items = items.map((s) => (s.id === id ? { ...s, state: "pending" } : s));
        loadError = e instanceof Error ? e.message : String(e);
        return;
      }
    }

    setTimeout(() => {
      items = items.filter((s) => s.id !== id || s.state === "pending");
    }, 600);
  }

  const pending = $derived(items.filter((s) => s.state === "pending"));
</script>

<div class="wrap">
  <header class="head">
    <h2>Inbox</h2>
    <p class="sub">
      {pending.length === 0 ? "All caught up." : `${pending.length} pending`}
      {#if liveMode}
        <span class="mode-tag live">live</span>
      {:else}
        <span class="mode-tag offline">offline</span>
      {/if}
    </p>
    {#if loadError}
      <div class="banner err" transition:slide={{ duration: 180 }}>
        <div>
          <strong>Couldn't reach broker.</strong>
          <span class="banner-detail">{loadError}</span>
        </div>
        <button type="button" class="banner-retry" onclick={load}>Retry</button>
      </div>
    {/if}
  </header>

  {#if items.length === 0 && !loading}
    <EmptyState
      title="Nothing in your inbox"
      blurb={liveMode
        ? "When someone shares a workbook directly with you, it lands here first."
        : "Engine isn't reachable. Once Workhorse is running and you've connected, shares from your friends land here."}
      glyph="✉"
      hue={220}
    />
  {:else}
    <div class="list">
      {#each items as s, i (s.id)}
        <div
          class="item"
          class:settled={s.state !== "pending"}
          in:fly={{ y: 6, duration: 220, delay: i * 50, easing: cubicOut }}
        >
          <div class="from">
            <Avatar
              handle={s.from}
              avatar={null}
              size="sm"
              verified={false}
            />
            <div class="from-text">
              <div class="line">
                <HandleChip handle={s.from} variant="inline" />
                <span class="muted">shared with you</span>
                <span class="dot">·</span>
                <span class="ts">{s.ts}</span>
              </div>
              {#if s.message}
                <p class="message">"{s.message}"</p>
              {/if}
            </div>
          </div>

          <ShareCard
            artifact={s.artifact}
            onclick={() => (preview = s.artifact)}
          />

          {#if s.state === "pending"}
            <div class="actions" transition:slide={{ duration: 200 }}>
              <button
                type="button"
                class="btn decline"
                onclick={() => settle(s.id, "declined")}
              >
                <X size={13} strokeWidth={2.25} />
                Decline
              </button>
              <button
                type="button"
                class="btn accept"
                onclick={() => settle(s.id, "accepted")}
              >
                <Check size={13} strokeWidth={2.25} />
                Accept · add to workspace
              </button>
            </div>
          {:else}
            <div class="settled-state" transition:slide={{ duration: 200 }}>
              {s.state === "accepted" ? "Added to your workspace ✓" : "Declined"}
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>

{#if preview}
  <PreviewPane artifact={preview} onclose={() => (preview = null)} />
{/if}

<style>
  .wrap {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    max-width: 620px;
    margin: 0 auto;
  }
  .head h2 {
    margin: 0 0 0.15rem;
    font-size: 1rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
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
  .banner {
    margin: 0.4rem 0 0;
    padding: 7px 12px;
    border-radius: 6px;
    font-size: 0.78rem;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: 10px;
    justify-content: space-between;
  }
  .banner.err {
    color: rgb(180, 50, 50);
    background: rgba(220, 60, 60, 0.08);
    border: 1px solid rgba(220, 60, 60, 0.22);
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

  .list { display: flex; flex-direction: column; gap: 0.75rem; }
  .item {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    padding: 0.95rem 1rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 14px;
    transition: opacity 240ms ease, border-color 200ms ease;
  }
  .item.settled { opacity: 0.6; }

  .from { display: flex; align-items: flex-start; gap: 0.55rem; }
  .from-text { flex: 1; min-width: 0; }
  .line {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 4px;
    font-size: 0.82rem;
  }
  .muted { color: var(--color-fg-muted); }
  .dot { color: var(--color-fg-subtle); }
  .ts { color: var(--color-fg-muted); font-size: 0.78rem; }
  .message {
    margin: 0.3rem 0 0;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
    font-style: italic;
    line-height: 1.5;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 6px;
  }
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
  .btn:hover { transform: translateY(-1px); }
  .btn.accept {
    background: var(--color-fg);
    color: var(--color-page);
    border: 1px solid var(--color-fg);
  }
  .btn.decline {
    background: transparent;
    color: var(--color-fg-muted);
    border: 1px solid var(--color-border-strong);
  }
  .btn.decline:hover { background: var(--color-surface-soft); color: var(--color-fg); }
  .settled-state {
    text-align: right;
    font-size: 0.8rem;
    font-weight: 500;
    color: var(--color-fg-muted);
  }
</style>
