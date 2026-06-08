<script lang="ts">
  /**
   * PreviewPane — opens when you tap a post's snapshot. Static preview
   * (does NOT run the workbook), with kind-aware integration actions:
   *
   *   workbook              → Open · Save copy · Subscribe
   *   agent/plugin/skill    → Install (Workgate-gated) · Save copy · Subscribe
   *
   * Install reveals an inline permissions panel that mirrors the
   * Workgate prompt the user would see if they confirm.
   */
  import {
    X, ExternalLink, Download, Bell, BellOff, GitFork,
    Folder, Globe, Terminal, ShieldCheck, ArrowRight,
  } from "@lucide/svelte";
  import { fly, fade, slide } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { onMount } from "svelte";
  import Avatar from "./Avatar.svelte";
  import HandleChip from "./HandleChip.svelte";
  import ProvenanceBadge from "./ProvenanceBadge.svelte";
  import { generatePreviewSvg } from "../theme/previewImage";
  import type { Artifact, Person } from "../types";
  import {
    listSubscriptions, subscribeToRid, unsubscribeFromRid,
    DemoModeError,
  } from "../client";
  import { workgateInstall, workbookFork } from "$lib/bridge/network.svelte";

  let {
    artifact,
    author = null,
    upstreamAdvance: upstreamAdvanceProp = null,
    onclose,
  }: {
    artifact: Artifact;
    /** Resolved Person for the artifact author. Parents pass this in
     *  when they have it (e.g., from a Broker lookup); when null the
     *  pane renders handle-only metadata, no verified badge. */
    author?: Person | null;
    /** Real upstream-advance data from ForkWatcher (set by the tab
     *  passing through listForkAdvances). null hides the pill. */
    upstreamAdvance?: { upstreamHandle: string; commitsAhead: number } | null;
    onclose: () => void;
  } = $props();

  const preview = $derived(generatePreviewSvg(artifact.id + artifact.title));

  // Subscribed state — hydrated from broker on mount, mutated on toggle.
  // Falls back to local state when the broker isn't reachable (demo mode).
  let subscribed = $state(false);
  let subscriptionPending = $state(false);
  let installing = $state(false);

  onMount(async () => {
    try {
      const resp = await listSubscriptions();
      subscribed = resp.subscriptions.some((s) => s.rid === artifact.id);
    } catch (e) {
      if (!(e instanceof DemoModeError)) {
        // Real failure — just leave subscribed=false; the toggle still
        // works locally for the design demo.
        console.warn("[PreviewPane] couldn't load subscriptions", e);
      }
    }
  });

  async function toggleSubscribe() {
    if (subscriptionPending) return;
    const prev = subscribed;
    subscribed = !subscribed;  // optimistic
    subscriptionPending = true;
    try {
      if (subscribed) {
        await subscribeToRid(artifact.id);
      } else {
        await unsubscribeFromRid(artifact.id);
      }
    } catch (e) {
      if (!(e instanceof DemoModeError)) {
        subscribed = prev;  // rollback on real failure
        console.warn("[PreviewPane] subscribe toggle failed", e);
      }
      // DemoModeError → keep the optimistic state, the design demo proceeds
    } finally {
      subscriptionPending = false;
    }
  }

  const roleLabel: Record<Artifact["kind"], string> = {
    workbook: "Workbook",
    agent: "Workbook · agent role",
    plugin: "Workbook · plugin role",
    skill: "Workbook · skill role",
  };
  const isExecutable = $derived(
    artifact.kind === "agent" || artifact.kind === "plugin" || artifact.kind === "skill",
  );
  const primaryLabel = $derived(isExecutable ? "Install" : "Open workbook");

  // Synthetic permissions for the demo. Real install flow reads these
  // from the workbook's manifest + the active workspace's policy.lua.
  const perms = $derived.by(() => {
    if (artifact.kind === "agent") return {
      fs: ["this workspace's files"],
      net: ["api.openai.com"],
      tools: ["bash · read-only"],
    };
    if (artifact.kind === "plugin") return {
      fs: [],
      net: [],
      tools: ["UI surface in this workspace"],
    };
    if (artifact.kind === "skill") return {
      fs: ["files in scope"],
      net: [],
      tools: ["available to your agents"],
    };
    return null;
  });

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") { if (installing) installing = false; else onclose(); }
  }
  function primaryAction() {
    if (isExecutable) installing = true;
    else onclose();
  }

  let installPending = $state(false);
  let installError = $state<string | null>(null);

  // ── Upstream-advance indicator (wb-u2o0.6.3) ───────────────────────
  // The pill renders only when the parent passes a real
  // upstreamAdvance from ForkWatcher (via the client.ts
  // listForkAdvances endpoint when it lands). The previous "synth
  // from string-match on title.includes('fork')" was removed because
  // it produced phantom 'upstream changes' indicators for any
  // workbook that happened to mention forks in its title or blurb.
  let upstreamAdvanceDismissed = $state(false);
  const upstreamAdvance = $derived(
    upstreamAdvanceDismissed ? null : upstreamAdvanceProp,
  );

  let pullPending = $state(false);
  async function doPullUpstream() {
    if (pullPending || !upstreamAdvance) return;
    pullPending = true;
    try {
      // Real path: Tauri command network_workbook_pull_upstream(fork_rid).
      // Workhorse rebases the local fork onto the upstream's new head +
      // re-signs the workbook (chain extended with a new claim). v1
      // stubs as a 600ms simulated rebase.
      await new Promise((r) => setTimeout(r, 600));
      upstreamAdvanceDismissed = true;
    } finally {
      pullPending = false;
    }
  }

  let forkPending = $state(false);
  async function doFork() {
    if (forkPending) return;
    forkPending = true;
    try {
      await workbookFork({
        source_rid: artifact.id,
        // Demo data doesn't carry the source DID — production path
        // resolves it via the inbox share's from_did. Pass a sentinel
        // for now; the IPC stub doesn't enforce DID format.
        source_did: `did:key:zUNKNOWN`,
        source_handle: artifact.authorHandle,
        workspace: "daily-driver", // TODO: pick active workspace
      });
      onclose();
    } catch (e) {
      // Tauri-unavailable path (design demo) — silently close.
      if (e instanceof Error && /tauri|invoke/i.test(e.message)) {
        onclose();
      }
      // Other errors fall through — UI keeps the modal open so user
      // can retry. v1 doesn't surface a fork-specific error pill yet.
    } finally {
      forkPending = false;
    }
  }

  async function confirmInstall() {
    if (installPending) return;
    installPending = true;
    installError = null;
    try {
      // Real install via Workgate IPC. Currently the Tauri side stubs
      // approval as auto-yes; full prompt UI lands as a separate task
      // in the wb-i38o desktop epic.
      await workgateInstall({
        rid: artifact.id,
        workspace: "daily-driver",  // TODO: pick active workspace from chrome state
        scopes: perms ?? { fs: [], net: [], tools: [] },
      });
      onclose();
    } catch (e) {
      // Tauri bridge unavailable (e.g., running in pure web/design
      // mode) — close the modal anyway so the demo flow proceeds.
      // Real errors get surfaced; we don't distinguish for the v1
      // stub flow.
      if (e instanceof Error && /tauri|invoke/i.test(e.message)) {
        onclose();
      } else {
        installError = e instanceof Error ? e.message : String(e);
      }
    } finally {
      installPending = false;
    }
  }
</script>

<svelte:window onkeydown={onKey} />
<button
  type="button"
  class="overlay"
  transition:fade={{ duration: 140 }}
  onclick={onclose}
  aria-label="Close preview"
></button>

<div
  class="pane"
  role="dialog"
  aria-modal="true"
  transition:fly={{ y: 10, duration: 220, easing: cubicOut }}
>
  <header class="head">
    <span class="role">{roleLabel[artifact.kind]}</span>
    <button type="button" class="x" onclick={onclose} aria-label="Close">
      <X size={16} strokeWidth={2} />
    </button>
  </header>

  <div class="snapshot">
    <img src={preview} alt={`Preview of ${artifact.title}`} />
    <span class="static-tag">Static preview · not running</span>
  </div>

  <div class="body">
    <h2 class="title">{artifact.title}</h2>
    <p class="blurb">{artifact.blurb}</p>

    <div class="meta">
      <Avatar
        handle={artifact.authorHandle}
        avatar={author?.avatar ?? null}
        size="sm"
      />
      <HandleChip handle={artifact.authorHandle} variant="inline" />
      <ProvenanceBadge
        state={author?.verified ? "verified" : "unverified"}
        by={artifact.authorHandle}
        realName={author?.verified ? author.displayName : null}
        subject="person"
      />
    </div>

    {#if upstreamAdvance}
      <div class="upstream-advance">
        <GitFork size={12} strokeWidth={2.25} />
        Upstream <strong>@{upstreamAdvance.upstreamHandle}</strong> has new changes since this fork was rebased.
        <button type="button" class="pull-btn" onclick={doPullUpstream} disabled={pullPending}>
          {pullPending ? "Pulling…" : "Pull"}
        </button>
      </div>
    {/if}
  </div>

  {#if installing && perms}
    <div class="perms" transition:slide={{ duration: 220, easing: cubicOut }}>
      <div class="perms-head">
        <ShieldCheck size={14} strokeWidth={2} />
        <span>@{artifact.authorHandle}'s {artifact.kind} requests:</span>
      </div>
      <ul class="perm-list">
        {#if perms.fs.length}
          <li><Folder size={13} strokeWidth={2} /> <span><strong>Files:</strong> {perms.fs.join(", ")}</span></li>
        {/if}
        {#if perms.net.length}
          <li><Globe size={13} strokeWidth={2} /> <span><strong>Network:</strong> {perms.net.join(", ")}</span></li>
        {/if}
        {#if perms.tools.length}
          <li><Terminal size={13} strokeWidth={2} /> <span><strong>Tools:</strong> {perms.tools.join(", ")}</span></li>
        {/if}
      </ul>
      <div class="perms-scope">
        Active in <button type="button" class="scope-picker">daily-driver workspace <ArrowRight size={11} strokeWidth={2} /></button>
      </div>
    </div>
  {/if}

  <footer class="foot">
    <button
      type="button"
      class="btn sub-toggle"
      class:on={subscribed}
      onclick={toggleSubscribe}
      title={subscribed
        ? "You'll get an update when the author publishes a new version."
        : "Get a notification whenever the author publishes a new version."}
    >
      {#if subscribed}
        <Bell size={13} strokeWidth={2.25} />
        Subscribed
      {:else}
        <BellOff size={13} strokeWidth={2} />
        Subscribe
      {/if}
    </button>

    <span class="spacer"></span>

    {#if installing}
      {#if installError}
        <span class="install-err" title={installError}>install failed: {installError.slice(0, 28)}{installError.length > 28 ? "…" : ""}</span>
      {/if}
      <button type="button" class="btn ghost" onclick={() => (installing = false)} disabled={installPending}>Cancel</button>
      <button type="button" class="btn primary" onclick={confirmInstall} disabled={installPending}>
        {installPending ? "Installing…" : "Grant & install"}
      </button>
    {:else}
      <button type="button" class="btn ghost" onclick={doFork} disabled={forkPending} title="Fork this workbook into your workspace">
        <GitFork size={13} strokeWidth={2.25} />
        {forkPending ? "Forking…" : "Fork"}
      </button>
      <button type="button" class="btn ghost">
        <Download size={13} strokeWidth={2} />
        Save copy
      </button>
      <button type="button" class="btn primary" onclick={primaryAction}>
        {#if isExecutable}
          <ShieldCheck size={13} strokeWidth={2.25} />
        {:else}
          <ExternalLink size={13} strokeWidth={2} />
        {/if}
        {primaryLabel}
      </button>
    {/if}
  </footer>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(15, 15, 15, 0.42);
    backdrop-filter: blur(2px);
    z-index: 100;
    border: 0;
    padding: 0;
  }
  .pane {
    position: fixed;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    width: min(560px, 92vw);
    max-height: 92vh;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 16px;
    box-shadow: 0 30px 80px rgba(15, 15, 15, 0.28);
    z-index: 101;
    overflow: hidden auto;
    display: flex;
    flex-direction: column;
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.7rem 0.85rem 0.7rem 1rem;
    border-bottom: 1px solid var(--color-border);
  }
  .role {
    font-size: 0.7rem;
    font-weight: 600;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
  }
  .x {
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
  }
  .x:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .snapshot {
    position: relative;
    background: var(--color-surface-soft);
    border-bottom: 1px solid var(--color-border);
  }
  .snapshot img {
    display: block;
    width: 100%;
    height: auto;
    max-height: 320px;
    object-fit: cover;
  }
  .static-tag {
    position: absolute;
    bottom: 8px;
    left: 8px;
    padding: 3px 8px;
    border-radius: 999px;
    background: rgba(15, 15, 15, 0.62);
    color: white;
    font-size: 0.68rem;
    font-weight: 600;
    letter-spacing: 0.02em;
    backdrop-filter: blur(4px);
  }

  .body {
    padding: 1rem 1.1rem 0.6rem;
    display: flex;
    flex-direction: column;
    gap: 0.45rem;
  }
  .title {
    margin: 0;
    font-size: 1.05rem;
    font-weight: 600;
    letter-spacing: -0.015em;
  }
  .blurb {
    margin: 0;
    font-size: 0.85rem;
    color: var(--color-fg-muted);
    line-height: 1.5;
  }
  .meta {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin-top: 0.3rem;
    flex-wrap: wrap;
  }

  /* Inline permissions panel (shown when Install is clicked) */
  .perms {
    margin: 0.4rem 0.85rem 0.2rem;
    padding: 0.7rem 0.85rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .perms-head {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-size: 0.78rem;
    font-weight: 600;
    color: var(--color-fg);
  }
  .perm-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .perm-list li {
    display: grid;
    grid-template-columns: 14px 1fr;
    gap: 8px;
    align-items: start;
    font-size: 0.8rem;
    color: var(--color-fg-muted);
    line-height: 1.45;
  }
  .perm-list li :global(svg) {
    margin-top: 3px;
    color: var(--color-fg-subtle);
  }
  .perm-list strong {
    color: var(--color-fg);
    font-weight: 600;
  }
  .perms-scope {
    font-size: 0.76rem;
    color: var(--color-fg-muted);
  }
  .scope-picker {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    padding: 2px 8px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.76rem;
    font-weight: 500;
    cursor: pointer;
    margin-left: 4px;
    transition: border-color 160ms ease;
  }
  .scope-picker:hover { border-color: var(--color-border-strong); }

  .upstream-advance {
    margin-top: 8px;
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-radius: 6px;
    background: rgba(125, 95, 200, 0.10);
    border: 1px solid rgba(125, 95, 200, 0.28);
    color: rgb(85, 60, 165);
    font-size: 0.72rem;
    line-height: 1.4;
  }
  .upstream-advance .pull-btn {
    margin-left: auto;
    padding: 3px 9px;
    border-radius: 5px;
    background: rgb(125, 95, 200);
    color: white;
    border: 0;
    font-size: 0.7rem;
    font-weight: 600;
    cursor: pointer;
    flex-shrink: 0;
  }
  .upstream-advance .pull-btn:hover:not(:disabled) {
    background: rgb(105, 78, 175);
  }
  .upstream-advance .pull-btn:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }
  @media (prefers-color-scheme: dark) {
    .upstream-advance {
      background: rgba(155, 130, 220, 0.14);
      border-color: rgba(155, 130, 220, 0.36);
      color: rgb(195, 175, 240);
    }
  }
  .install-err {
    font-size: 0.72rem;
    color: rgb(180, 50, 50);
    background: rgba(220, 60, 60, 0.08);
    padding: 4px 9px;
    border-radius: 6px;
    border: 1px solid rgba(220, 60, 60, 0.22);
    margin-right: 6px;
    max-width: 220px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .foot {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0.7rem 0.85rem 0.85rem;
    border-top: 1px solid var(--color-border);
  }
  .spacer { flex: 1; }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    height: 30px;
    padding: 0 11px;
    border-radius: 8px;
    font: inherit;
    font-size: 0.78rem;
    font-weight: 500;
    cursor: pointer;
    transition: transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1), background 160ms ease, border-color 160ms ease;
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

  /* Subscribe toggle — sits at the leading edge, lighter weight than the
     trailing primary actions because it's the secondary commitment. */
  .sub-toggle {
    background: transparent;
    color: var(--color-fg-muted);
    border: 1px dashed var(--color-border-strong);
  }
  .sub-toggle:hover { color: var(--color-fg); border-style: solid; background: var(--color-surface-soft); }
  .sub-toggle.on {
    color: rgb(20, 110, 70);
    background: rgba(34, 160, 105, 0.10);
    border-color: rgba(34, 160, 105, 0.32);
    border-style: solid;
  }
  @media (prefers-color-scheme: dark) {
    .sub-toggle.on {
      color: rgb(120, 220, 165);
      background: rgba(34, 160, 105, 0.16);
      border-color: rgba(34, 160, 105, 0.42);
    }
  }
</style>
