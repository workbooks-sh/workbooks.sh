<script lang="ts">
  /**
   * SubscriptionsTab — list + manage subscribed artifacts (wb-u2o0.4.3).
   *
   * Each row is a RID the user follows. Rows where the current
   * Radicle HEAD differs from last_seen_commit get an "Update
   * available" badge. Tap row → opens PreviewPane on the artifact.
   * Tap Unsubscribe → drops it.
   *
   * Live data comes from GET /v1/network/subscriptions; falls back to
   * fixture data when broker is unreachable so the design demo holds.
   */
  import { onMount } from "svelte";
  import { fly, slide } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { Bell, BellOff, Sparkles, ExternalLink } from "@lucide/svelte";
  import EmptyState from "../components/EmptyState.svelte";
  import PreviewPane from "../components/PreviewPane.svelte";
  import {
    listSubscriptions, unsubscribeFromRid,
    DemoModeError, type SubscriptionView,
  } from "../client";
  import type { Artifact } from "../types";

  let subscriptions = $state<SubscriptionView[]>([]);
  let loading = $state(true);
  let liveMode = $state(false);
  let loadError = $state<string | null>(null);
  let preview = $state<Artifact | null>(null);

  onMount(load);

  async function load() {
    loading = true;
    loadError = null;
    try {
      const resp = await listSubscriptions();
      subscriptions = resp.subscriptions;
      liveMode = true;
    } catch (e) {
      if (e instanceof DemoModeError) {
        // Sidecar unreachable. Empty state (fixture data removed).
        subscriptions = [];
        liveMode = false;
      } else {
        // Real failure: empty list + banner with retry.
        subscriptions = [];
        liveMode = true;
        loadError = e instanceof Error ? e.message : String(e);
      }
    } finally {
      loading = false;
    }
  }

  async function unsubscribe(rid: string) {
    const original = subscriptions;
    subscriptions = subscriptions.filter((s) => s.rid !== rid);
    try {
      if (liveMode) await unsubscribeFromRid(rid);
    } catch (e) {
      subscriptions = original;
      loadError = e instanceof Error ? e.message : String(e);
    }
  }

  function shortRid(rid: string): string {
    const r = rid.replace(/^rad:/, "");
    return `rad:${r.slice(0, 6)}…${r.slice(-4)}`;
  }

  function relTime(ms: number): string {
    const dt = Date.now() - ms;
    if (dt < 86_400_000) return `${Math.round(dt / 3_600_000)}h`;
    if (dt < 7 * 86_400_000) return `${Math.round(dt / 86_400_000)}d`;
    return new Date(ms).toISOString().slice(0, 10);
  }

  // Build a minimal Artifact stub from a subscription row for preview
  // purposes. The real workbook title/blurb/author live in Radicle;
  // the Workhorse subscription clone surfaces them once pulled. Until
  // that pull-side wires up, we show the rid + a placeholder.
  function previewFor(sub: SubscriptionView): Artifact {
    return {
      id: sub.rid,
      kind: "workbook",
      title: shortRid(sub.rid),
      blurb: "Subscribed workbook — preview loads when Workhorse fetches the artifact.",
      authorHandle: "unknown",
      thumbnailEmoji: "📦",
      verified: false,
    };
  }

  // "Update available" — current head > last_seen_commit. The
  // listForkAdvances / subscription head endpoint surfaces this real
  // signal; until then we approximate it as "last_seen_at is stale
  // or never set".
  function hasUpdate(sub: SubscriptionView): boolean {
    if (sub.last_seen_at == null) return true;  // never acked
    return Date.now() - sub.last_seen_at > 2 * 86_400_000;
  }

  const updateCount = $derived(subscriptions.filter(hasUpdate).length);
</script>

<div class="wrap">
  <header class="head">
    <div>
      <h2>Subscriptions</h2>
      <p class="sub">
        {subscriptions.length} subscribed
        {#if updateCount > 0}· <span class="update-count">{updateCount} with updates</span>{/if}
        {#if liveMode}
          <span class="mode-tag live">live</span>
        {:else}
          <span class="mode-tag offline">offline</span>
        {/if}
      </p>
    </div>
  </header>

  {#if loadError}
    <div class="banner err">
      <div>
        <strong>Couldn't reach broker.</strong>
        <span class="banner-detail">{loadError}</span>
      </div>
      <button type="button" class="banner-retry" onclick={load}>Retry</button>
    </div>
  {/if}

  {#if subscriptions.length === 0 && !loading}
    <EmptyState
      title="Not following anything yet"
      blurb={liveMode
        ? "Open a workbook from your inbox, then tap Subscribe to follow it. New versions will surface here."
        : "Engine isn't reachable. Once Workhorse is running and you're connected, your follows will show up here."}
      glyph="❀"
      hue={150}
    />
  {:else}
    <div class="list">
      {#each subscriptions as sub, i (sub.rid)}
        {@const art = previewFor(sub)}
        {@const updates = hasUpdate(sub)}
        <div class="row" class:has-update={updates} in:fly={{ y: 4, duration: 200, delay: i * 35, easing: cubicOut }}>
          <button type="button" class="row-main" onclick={() => (preview = art)}>
            <span class="emoji">{art.thumbnailEmoji}</span>
            <span class="row-body">
              <span class="title">{art.title}</span>
              <span class="meta">
                {#if art.authorHandle && art.authorHandle !== "unknown"}
                  @{art.authorHandle} ·
                {/if}
                subscribed {relTime(sub.subscribed_at)}
                {#if sub.last_seen_at}
                  · last seen {relTime(sub.last_seen_at)}
                {:else}
                  · <em>not yet seen</em>
                {/if}
              </span>
            </span>
            {#if updates}
              <span class="badge update" transition:slide={{ duration: 180 }}>
                <Sparkles size={11} strokeWidth={2.25} /> Update
              </span>
            {/if}
            <ExternalLink size={12} strokeWidth={2} class="row-arrow" />
          </button>
          <button type="button" class="unsub" onclick={() => unsubscribe(sub.rid)} title="Unsubscribe">
            <BellOff size={13} strokeWidth={2} />
          </button>
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
  .head h2 { margin: 0 0 .15rem; font-size: 1rem; font-weight: 600; letter-spacing: -.01em; }
  .head .sub {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .update-count {
    color: rgb(20, 110, 70);
    font-weight: 600;
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

  .list { display: flex; flex-direction: column; gap: 0.4rem; }
  .row {
    display: grid;
    grid-template-columns: 1fr auto;
    align-items: stretch;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 11px;
    overflow: hidden;
    transition: border-color 200ms ease;
  }
  .row:hover { border-color: var(--color-border-strong); }
  .row.has-update {
    border-color: rgba(34, 160, 105, 0.32);
    background: rgba(34, 160, 105, 0.04);
  }

  .row-main {
    display: grid;
    grid-template-columns: 38px 1fr auto auto;
    align-items: center;
    gap: 10px;
    padding: 0.6rem 0.7rem;
    background: transparent;
    border: 0;
    text-align: left;
    color: var(--color-fg);
    cursor: pointer;
    font: inherit;
  }
  .emoji {
    width: 38px; height: 38px;
    display: inline-flex; align-items: center; justify-content: center;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    font-size: 1.2rem;
    line-height: 1;
  }
  .row-body { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .title {
    font-size: 0.88rem; font-weight: 600;
    letter-spacing: -0.01em;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .meta { font-size: 0.74rem; color: var(--color-fg-muted); }
  em { font-style: italic; color: var(--color-fg-subtle); }
  :global(.row-arrow) { color: var(--color-fg-subtle); }

  .badge {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    padding: 2px 7px;
    border-radius: 999px;
    font-size: 0.66rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    line-height: 1.4;
  }
  .badge.update {
    color: rgb(20, 110, 70);
    background: rgba(34, 160, 105, 0.14);
    border: 1px solid rgba(34, 160, 105, 0.32);
  }

  .unsub {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 38px;
    padding: 0;
    background: transparent;
    border: 0;
    border-left: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: background 140ms ease, color 140ms ease;
  }
  .unsub:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
</style>
