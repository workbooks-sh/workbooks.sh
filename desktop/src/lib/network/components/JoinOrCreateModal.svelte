<script lang="ts">
  /**
   * JoinOrCreateModal — two paths from the [+] chip:
   *   1. Create a network you own
   *   2. Join one via an invite code or link someone sent you
   *
   * No public discovery. Joining requires either being added by a
   * network owner or pasting an invite they shared with you — matches
   * the friends-only model.
   */
  import { fly, fade } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { X, ArrowLeft, ArrowRight, Plus, KeyRound, Lock, Globe, Users, Sparkles } from "@lucide/svelte";

  let {
    onclose,
  }: {
    onclose: () => void;
  } = $props();

  type Screen = "choice" | "create" | "join";
  let screen = $state<Screen>("choice");

  // Create form state
  let cName = $state("");
  let cBlurb = $state("");
  let cKind = $state<"personal" | "project">("personal");
  let cJoin = $state<"open" | "request" | "invite">("invite");

  // Join form state
  let jCode = $state("");
  const jClean = $derived(jCode.trim());
  const jValid = $derived(jClean.length >= 6);

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") onclose();
  }

  function back() { screen = "choice"; }

  function submitCreate() {
    // Phase 1 wires this to POST /v1/network/networks. Demo: just close.
    onclose();
  }
  function submitJoin() {
    // Phase 1 wires this to invite-code resolution. Demo: just close.
    onclose();
  }
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
    {#if screen !== "choice"}
      <button type="button" class="back" onclick={back} aria-label="Back">
        <ArrowLeft size={15} strokeWidth={2} />
      </button>
    {/if}
    <h2>
      {#if screen === "choice"}Add a network
      {:else if screen === "create"}Create a network
      {:else}Join with an invite
      {/if}
    </h2>
    <button type="button" class="x" onclick={onclose} aria-label="Close">
      <X size={15} strokeWidth={2} />
    </button>
  </header>

  {#if screen === "choice"}
    <div class="choice">
      <button type="button" class="choice-card" onclick={() => (screen = "create")}>
        <span class="ico"><Plus size={20} strokeWidth={2} /></span>
        <span class="t">
          <span class="t-name">Create a network</span>
          <span class="t-sub">A circle of friends, a project group, or a team space you own.</span>
        </span>
        <ArrowRight size={14} strokeWidth={2} class="arrow" />
      </button>
      <button type="button" class="choice-card" onclick={() => (screen = "join")}>
        <span class="ico"><KeyRound size={18} strokeWidth={2} /></span>
        <span class="t">
          <span class="t-name">Join with an invite</span>
          <span class="t-sub">Paste a code or link someone shared with you.</span>
        </span>
        <ArrowRight size={14} strokeWidth={2} class="arrow" />
      </button>
      <p class="hint">
        Workbooks Network is invite-only by design. There's no public directory.
      </p>
    </div>
  {:else if screen === "create"}
    <form class="form" onsubmit={(e) => { e.preventDefault(); submitCreate(); }}>
      <label class="field">
        <span class="lbl">Name</span>
        <input
          type="text"
          bind:value={cName}
          placeholder="e.g. Tuesday drafts"
          maxlength={48}
          required
        />
      </label>

      <label class="field">
        <span class="lbl">What's it for?</span>
        <textarea
          bind:value={cBlurb}
          rows="2"
          placeholder="One sentence members will see when they open the network."
          maxlength={160}
        ></textarea>
      </label>

      <div class="field">
        <span class="lbl">Network type</span>
        <div class="radio-grid">
          <label class="radio" class:active={cKind === "personal"}>
            <input type="radio" bind:group={cKind} value="personal" />
            <Users size={14} strokeWidth={2} />
            <span class="r-body">
              <span class="r-name">Personal circle</span>
              <span class="r-sub">A small group you hand-pick.</span>
            </span>
          </label>
          <label class="radio" class:active={cKind === "project"}>
            <input type="radio" bind:group={cKind} value="project" />
            <Sparkles size={14} strokeWidth={2} />
            <span class="r-body">
              <span class="r-name">Project</span>
              <span class="r-sub">Bound to a topic or shared work.</span>
            </span>
          </label>
        </div>
      </div>

      <div class="field">
        <span class="lbl">Who can join</span>
        <div class="radio-row">
          <label class="seg" class:active={cJoin === "invite"}>
            <input type="radio" bind:group={cJoin} value="invite" />
            <Lock size={12} strokeWidth={2} />
            Invite-only
          </label>
          <label class="seg" class:active={cJoin === "request"}>
            <input type="radio" bind:group={cJoin} value="request" />
            <KeyRound size={12} strokeWidth={2} />
            Request
          </label>
          <label class="seg" class:active={cJoin === "open"}>
            <input type="radio" bind:group={cJoin} value="open" />
            <Globe size={12} strokeWidth={2} />
            Open
          </label>
        </div>
      </div>

      <footer class="foot">
        <button type="button" class="btn ghost" onclick={onclose}>Cancel</button>
        <button type="submit" class="btn primary" disabled={!cName.trim()}>
          Create network
        </button>
      </footer>
    </form>
  {:else}
    <form class="form" onsubmit={(e) => { e.preventDefault(); if (jValid) submitJoin(); }}>
      <label class="field">
        <span class="lbl">Invite code or link</span>
        <input
          type="text"
          bind:value={jCode}
          placeholder="WB-A3F2-K9LM  or  workbooks://join/…"
          autocomplete="off"
          spellcheck={false}
        />
      </label>

      <p class="help">
        Don't have a code? Ask the person who runs the network to send you
        an invite. There's no public list to browse.
      </p>

      <footer class="foot">
        <button type="button" class="btn ghost" onclick={onclose}>Cancel</button>
        <button type="submit" class="btn primary" disabled={!jValid}>
          Join network
        </button>
      </footer>
    </form>
  {/if}
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
    width: min(480px, 92vw);
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
    display: grid;
    grid-template-columns: 28px 1fr 28px;
    align-items: center;
    padding: 0.7rem 0.85rem 0.7rem;
    border-bottom: 1px solid var(--color-border);
  }
  .head h2 {
    margin: 0;
    text-align: center;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .x, .back {
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
    transition: background 140ms ease, color 140ms ease;
  }
  .x:hover, .back:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  /* Choice screen */
  .choice {
    padding: 0.85rem;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .choice-card {
    display: grid;
    grid-template-columns: 36px 1fr auto;
    align-items: center;
    gap: 12px;
    padding: 14px 14px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    color: var(--color-fg);
    font: inherit;
    text-align: left;
    cursor: pointer;
    transition:
      transform 200ms cubic-bezier(0.22, 1.2, 0.36, 1),
      border-color 200ms ease,
      box-shadow 200ms ease;
  }
  .choice-card:hover {
    transform: translateY(-2px);
    border-color: var(--color-border-strong);
    box-shadow: 0 6px 18px rgba(15, 15, 15, 0.05);
  }
  .ico {
    width: 36px;
    height: 36px;
    border-radius: 10px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
  }
  .t { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .t-name {
    font-size: 0.92rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .t-sub {
    font-size: 0.78rem;
    color: var(--color-fg-muted);
    line-height: 1.4;
  }
  :global(.arrow) { color: var(--color-fg-subtle); }
  .choice-card:hover :global(.arrow) { color: var(--color-fg); }

  .hint {
    margin: 0.4rem 0.3rem 0.1rem;
    text-align: center;
    color: var(--color-fg-subtle);
    font-size: 0.74rem;
    line-height: 1.5;
  }

  /* Forms */
  .form {
    padding: 0.9rem;
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
  }
  .field { display: flex; flex-direction: column; gap: 6px; }
  .lbl {
    font-size: 0.74rem;
    font-weight: 600;
    color: var(--color-fg-muted);
    letter-spacing: -0.005em;
  }
  .form input[type="text"],
  .form textarea {
    width: 100%;
    padding: 9px 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border-strong);
    border-radius: 8px;
    font: inherit;
    font-size: 0.86rem;
    color: var(--color-fg);
    transition: border-color 160ms ease, box-shadow 160ms ease, background 160ms ease;
  }
  .form input[type="text"]:focus,
  .form textarea:focus {
    outline: none;
    border-color: var(--color-fg);
    background: var(--color-surface);
    box-shadow: 0 0 0 3px var(--color-ring);
  }
  .form textarea { resize: vertical; min-height: 56px; }

  /* Big radios (network type) */
  .radio-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
  }
  .radio {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 8px;
    align-items: flex-start;
    padding: 10px 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    cursor: pointer;
    transition: border-color 160ms ease, background 160ms ease;
  }
  .radio:hover { border-color: var(--color-border-strong); }
  .radio.active {
    border-color: var(--color-fg);
    background: var(--color-surface);
    box-shadow: 0 0 0 2px var(--color-ring);
  }
  .radio input { position: absolute; opacity: 0; pointer-events: none; }
  .r-body { display: flex; flex-direction: column; gap: 1px; }
  .r-name { font-size: 0.82rem; font-weight: 600; }
  .r-sub { font-size: 0.74rem; color: var(--color-fg-muted); line-height: 1.4; }

  /* Segmented (visibility) */
  .radio-row {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    align-self: flex-start;
  }
  .seg {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 6px 12px;
    border-radius: 999px;
    font-size: 0.78rem;
    font-weight: 500;
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: background 160ms ease, color 160ms ease;
  }
  .seg input { position: absolute; opacity: 0; pointer-events: none; }
  .seg:hover { color: var(--color-fg); }
  .seg.active {
    background: var(--color-surface);
    color: var(--color-fg);
    box-shadow: inset 0 0 0 1px var(--color-border-strong);
  }

  .help {
    margin: -0.3rem 0.15rem 0;
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    line-height: 1.5;
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    padding-top: 0.3rem;
  }
  .btn {
    height: 32px;
    padding: 0 14px;
    border-radius: 8px;
    font: inherit;
    font-size: 0.83rem;
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
