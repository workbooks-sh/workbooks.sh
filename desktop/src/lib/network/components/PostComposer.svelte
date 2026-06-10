<script lang="ts">
  /**
   * PostComposer — modal flow for publishing a workbook to one of your
   * networks. Three pieces:
   *   1. Pick which network the post lands in
   *   2. Pick a workbook from your library (or browse)
   *   3. Add an optional message + see how the post will be signed
   *
   * In Phase 1 this calls Workhorse.Publisher; in the demo it just
   * closes on submit.
   */
  import { X, FolderOpen, Check, ShieldCheck } from "phosphor-svelte";
  import { untrack } from "svelte";
  import { fly, fade, slide } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import Avatar from "./Avatar.svelte";
  import type { Artifact, Network } from "../types";

  let {
    initialNetworkId = null,
    handle = null,
    networks = [],
    myPublished = [],
    onclose,
  }: {
    initialNetworkId?: string | null;
    /** Current user's handle — drives the "Signed as @handle" footer. */
    handle?: string | null;
    /** Networks the user can post into. Empty until a Broker
     *  networks endpoint lands. */
    networks?: Network[];
    /** User's published workbooks. Empty until the Broker exposes
     *  a per-user share listing. */
    myPublished?: Artifact[];
    onclose: () => void;
  } = $props();

  // Selected network — initialized once from the prop (the modal is
  // recreated each open, so we never need to track prop changes).
  let networkId = $state<string | null>(
    untrack(() =>
      initialNetworkId && networks.some((n) => n.id === initialNetworkId)
        ? initialNetworkId
        : networks[0]?.id ?? null,
    ),
  );
  const selectedNetwork = $derived(
    networkId ? networks.find((n) => n.id === networkId) ?? null : null,
  );

  // Selected workbook
  let selected = $state<Artifact | null>(null);
  let message = $state("");

  const canPost = $derived(!!selectedNetwork && !!selected);

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") onclose();
  }

  function submit() {
    if (!canPost) return;
    // Phase 1 wires this to Workhorse.Publisher.publish/3
    onclose();
  }

  function hash(s: string): number {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return Math.abs(h);
  }

  const roleTag: Record<Artifact["kind"], string> = {
    workbook: "workbook",
    agent: "agent",
    plugin: "plugin",
    skill: "skill",
  };
</script>

<svelte:window onkeydown={onKey} />
<button
  type="button"
  class="overlay"
  transition:fade={{ duration: 140 }}
  onclick={onclose}
  aria-label="Close"
></button>

<div
  class="pane"
  role="dialog"
  aria-modal="true"
  transition:fly={{ y: 10, duration: 220, easing: cubicOut }}
>
  <header class="head">
    <h2>New post</h2>
    <button type="button" class="x" onclick={onclose} aria-label="Close">
      <X weight="bold" size={16} />
    </button>
  </header>

  <div class="body">
    <!-- Network picker -->
    <section class="field">
      <span class="lbl">Post to</span>
      <div class="chips">
        {#each networks as n (n.id)}
          <button
            type="button"
            class="chip"
            class:on={networkId === n.id}
            style:--vibe-h={hash(n.id) % 360}
            onclick={() => (networkId = n.id)}
          >
            <span class="dot" aria-hidden="true"></span>
            {n.name}
          </button>
        {/each}
      </div>
    </section>

    <!-- Workbook picker -->
    <section class="field">
      <div class="row-head">
        <span class="lbl">What are you sharing?</span>
        <button type="button" class="browse">
          <FolderOpen weight="fill" size={12} />
          Browse files…
        </button>
      </div>
      <div class="wb-list" role="radiogroup">
        {#each myPublished as a (a.id)}
          <button
            type="button"
            role="radio"
            aria-checked={selected?.id === a.id}
            class="wb"
            class:on={selected?.id === a.id}
            onclick={() => (selected = a)}
          >
            <span class="favicon" aria-hidden="true">{a.thumbnailEmoji}</span>
            <span class="wb-body">
              <span class="wb-meta">
                <span class="role">{roleTag[a.kind]}</span>
                <span class="dot">·</span>
                <span class="muted">just now</span>
              </span>
              <span class="wb-title">{a.title}</span>
              <span class="wb-blurb">{a.blurb}</span>
            </span>
            {#if selected?.id === a.id}
              <span class="picked"><Check weight="bold" size={13} /></span>
            {/if}
          </button>
        {:else}
          <p class="wb-empty">
            No published workbooks yet. Use <strong>Browse files…</strong> above to pick a workbook `.html` from disk.
          </p>
        {/each}
      </div>
    </section>

    <!-- Optional message -->
    {#if selected}
      <section class="field" transition:slide={{ duration: 200, easing: cubicOut }}>
        <span class="lbl">Add a message <span class="opt">— optional</span></span>
        <textarea
          bind:value={message}
          rows="2"
          maxlength={280}
          placeholder="What should people know about this?"
        ></textarea>
      </section>
    {/if}
  </div>

  <footer class="foot">
    <div class="signed">
      <Avatar handle={handle ?? "?"} avatar={null} size="xs" />
      <ShieldCheck weight="fill" size={11} class="signed-shield" />
      <span>
        {#if handle}
          Signed as <strong>@{handle}</strong>
        {:else}
          Not connected — sign-in needed before posting
        {/if}
      </span>
    </div>
    <div class="actions">
      <button type="button" class="btn ghost" onclick={onclose}>Cancel</button>
      <button type="button" class="btn primary" disabled={!canPost} onclick={submit}>
        Post {selectedNetwork ? `to ${selectedNetwork.name}` : ""}
      </button>
    </div>
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
    overflow: hidden;
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
  .head h2 {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .x {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border-radius: 7px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
  }
  .x:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .body {
    padding: 1rem;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .lbl {
    font-size: 0.74rem;
    font-weight: 600;
    color: var(--color-fg-muted);
    letter-spacing: -0.005em;
  }
  .opt {
    color: var(--color-fg-subtle);
    font-weight: 400;
    font-style: italic;
  }

  .row-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
  }
  .browse {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.74rem;
    font-weight: 500;
    cursor: pointer;
    padding: 2px 6px;
    border-radius: 6px;
    transition: background 140ms ease, color 140ms ease;
  }
  .browse:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  /* Network chips */
  .chips {
    display: inline-flex;
    flex-wrap: wrap;
    gap: 4px;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.8rem;
    font-weight: 500;
    border-radius: 999px;
    cursor: pointer;
    transition: color 160ms ease, border-color 160ms ease, background 160ms ease;
  }
  .chip .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: hsl(var(--vibe-h) 55% 55%);
    box-shadow: 0 0 0 1.5px hsl(var(--vibe-h) 55% 55% / 0.22);
  }
  .chip:hover { color: var(--color-fg); border-color: var(--color-border-strong); }
  .chip.on {
    color: var(--color-fg);
    background: var(--color-surface);
    border-color: var(--color-fg);
    box-shadow: 0 0 0 2px var(--color-ring);
  }

  /* Workbook picker rows */
  .wb-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
    max-height: 220px;
    overflow-y: auto;
  }
  .wb {
    display: grid;
    grid-template-columns: 42px 1fr auto;
    gap: 11px;
    align-items: center;
    padding: 9px 11px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    text-align: left;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    transition: border-color 140ms ease, background 140ms ease, transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .wb:hover { border-color: var(--color-border-strong); }
  .wb.on {
    border-color: var(--color-fg);
    background: var(--color-surface-soft);
    box-shadow: 0 0 0 2px var(--color-ring);
  }
  .favicon {
    width: 42px;
    height: 42px;
    border-radius: 9px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    font-size: 1.2rem;
    line-height: 1;
  }
  .wb.on .favicon { background: var(--color-surface); }
  .wb-body {
    display: inline-flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }
  .wb-meta {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 0.68rem;
    color: var(--color-fg-subtle);
  }
  .role { text-transform: uppercase; font-weight: 600; letter-spacing: 0.05em; }
  .muted { color: var(--color-fg-muted); }
  .dot { color: var(--color-fg-subtle); }
  .wb-title {
    font-size: 0.86rem;
    font-weight: 600;
    letter-spacing: -0.01em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .wb-blurb {
    font-size: 0.76rem;
    color: var(--color-fg-muted);
    line-height: 1.4;
    display: -webkit-box;
    -webkit-line-clamp: 1;
    line-clamp: 1;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .picked {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background: var(--color-fg);
    color: var(--color-page);
  }

  /* Message */
  textarea {
    width: 100%;
    padding: 9px 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border-strong);
    border-radius: 8px;
    font: inherit;
    font-size: 0.86rem;
    color: var(--color-fg);
    resize: vertical;
    min-height: 56px;
    transition: border-color 160ms ease, box-shadow 160ms ease, background 160ms ease;
  }
  textarea:focus {
    outline: none;
    border-color: var(--color-fg);
    background: var(--color-surface);
    box-shadow: 0 0 0 3px var(--color-ring);
  }

  .foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.7rem;
    padding: 0.7rem 0.85rem 0.85rem;
    border-top: 1px solid var(--color-border);
  }
  .signed {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 0.76rem;
    color: var(--color-fg-muted);
  }
  :global(.signed-shield) {
    color: rgb(34, 160, 105);
  }
  .signed strong {
    color: var(--color-fg);
    font-weight: 600;
  }
  .actions {
    display: inline-flex;
    align-items: center;
    gap: 6px;
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
  .btn:hover:not(:disabled) { transform: translateY(-1px); }
  .btn:disabled { opacity: 0.5; cursor: not-allowed; }
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
