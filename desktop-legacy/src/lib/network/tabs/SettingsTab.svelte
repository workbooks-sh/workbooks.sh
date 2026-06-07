<script lang="ts">
  /**
   * SettingsTab — handle, identity, WorkOS link state, notification
   * preferences.
   *
   * Identity comes from loadIdentity() at mount. Notification toggles
   * + key-rotation actions are visual-only today — they wire up to
   * Workhorse settings when those endpoints land.
   */
  import { onMount } from "svelte";
  import { KeyRound, AtSign, ShieldCheck, Bell, Copy } from "@lucide/svelte";
  import Avatar from "../components/Avatar.svelte";
  import EmptyState from "../components/EmptyState.svelte";
  import { loadIdentity, type IdentityView } from "$lib/bridge/network.svelte";

  let me = $state<IdentityView | null>(null);
  let loading = $state(true);

  onMount(async () => {
    try {
      me = await loadIdentity();
    } catch {
      // Sidecar unreachable — me stays null, empty state renders.
    } finally {
      loading = false;
    }
  });

  let notifShares = $state(true);
  let notifUpdates = $state(true);
  let notifMentions = $state(true);
  let notifDigest = $state(false);
</script>

<div class="wrap">
  <header class="head">
    <h2>Settings</h2>
  </header>

  {#if me}
    <section class="card">
      <div class="card-head">
        <AtSign size={15} strokeWidth={2} />
        <h3>Identity</h3>
      </div>
      <div class="ident">
        <Avatar handle={me.handle ?? "?"} avatar={null} size="lg" verified={!!me.workos_user_id} />
        <div class="ident-body">
          <div class="row">
            <span class="label">Handle</span>
            <span class="val">{me.handle ? `@${me.handle}` : "(unset)"}</span>
            <button class="link">Change</button>
          </div>
          <div class="row">
            <span class="label">DID</span>
            <span class="val mono">{me.did}</span>
            <button
              class="link icon"
              onclick={() => navigator.clipboard?.writeText(me!.did)}
              title="Copy DID"
            >
              <Copy size={12} strokeWidth={2.25} />
            </button>
          </div>
        </div>
      </div>
    </section>

    <section class="card">
      <div class="card-head">
        <ShieldCheck size={15} strokeWidth={2} />
        <h3>Verification</h3>
      </div>
      <div class="row">
        <span class="label">Real-name verification</span>
        <span class="val">
          {#if me.workos_user_id}
            <span class="pill ok">On file</span>
            Your verified name shows next to shares you publish.
          {:else}
            <span class="pill muted">Not on file</span>
            Sign in to Workbooks with a real-name account to add a verified badge to your shares.
          {/if}
        </span>
        <button class="link">Manage</button>
      </div>
    </section>

    <section class="card">
      <div class="card-head">
        <KeyRound size={15} strokeWidth={2} />
        <h3>Keys</h3>
      </div>
      <div class="row">
        <span class="label">Signing key</span>
        <span class="val mono">{me.public_key_b64.slice(0, 12)}…</span>
        <button class="link">Rotate</button>
      </div>
    </section>
  {:else if !loading}
    <EmptyState
      title="Not connected"
      blurb="Connect to Workhorse to manage your identity. The Connect button is in the top-right of the Network panel."
      glyph="◌"
    />
  {/if}

  <section class="card">
    <div class="card-head">
      <Bell size={15} strokeWidth={2} />
      <h3>Notifications</h3>
    </div>
    <label class="toggle-row">
      <span class="toggle-label">
        <span class="t-name">Direct shares</span>
        <span class="t-sub">When someone shares a workbook directly with you.</span>
      </span>
      <input type="checkbox" bind:checked={notifShares} class="toggle" />
    </label>
    <label class="toggle-row">
      <span class="toggle-label">
        <span class="t-name">Updates to things I subscribe to</span>
        <span class="t-sub">A plugin or agent you follow ships a new version.</span>
      </span>
      <input type="checkbox" bind:checked={notifUpdates} class="toggle" />
    </label>
    <label class="toggle-row">
      <span class="toggle-label">
        <span class="t-name">Mentions and comments</span>
        <span class="t-sub">Someone @-mentions you or comments on your work.</span>
      </span>
      <input type="checkbox" bind:checked={notifMentions} class="toggle" />
    </label>
    <label class="toggle-row">
      <span class="toggle-label">
        <span class="t-name">Weekly digest</span>
        <span class="t-sub">A Monday-morning summary of what your networks shipped.</span>
      </span>
      <input type="checkbox" bind:checked={notifDigest} class="toggle" />
    </label>
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
  .head h2 {
    margin: 0 0 0.2rem;
    font-size: 1rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .card {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    padding: 1rem 1.1rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
  }
  .card-head {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    color: var(--color-fg-subtle);
  }
  .card-head h3 {
    margin: 0;
    font-size: 0.74rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-fg-subtle);
  }
  .ident {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 0.9rem;
    align-items: flex-start;
  }
  .ident-body {
    display: flex;
    flex-direction: column;
    gap: 0.45rem;
  }
  .row {
    display: grid;
    grid-template-columns: 110px 1fr auto;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.84rem;
  }
  .label {
    color: var(--color-fg-muted);
    font-size: 0.78rem;
  }
  .val { color: var(--color-fg); }
  .val.mono {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.78rem;
    word-break: break-all;
    color: var(--color-fg-muted);
  }
  .val.muted { color: var(--color-fg-muted); }
  .link {
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.78rem;
    font-weight: 500;
    cursor: pointer;
    padding: 4px 8px;
    border-radius: 6px;
    transition: background 160ms ease;
  }
  .link:hover { background: var(--color-surface-soft); }
  .link.icon {
    display: inline-flex;
    align-items: center;
    color: var(--color-fg-muted);
  }
  .pill {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: 999px;
    font-size: 0.7rem;
    font-weight: 600;
    margin-right: 6px;
  }
  .pill.ok {
    color: rgb(20, 110, 70);
    background: rgba(34, 160, 105, 0.12);
  }
  .pill.muted {
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
  }

  .toggle-row {
    display: grid;
    grid-template-columns: 1fr auto;
    align-items: center;
    gap: 1rem;
    padding: 0.5rem 0;
    border-top: 1px solid var(--color-border);
  }
  .toggle-row:first-of-type { border-top: 0; padding-top: 0.2rem; }
  .toggle-label {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .t-name { font-size: 0.85rem; font-weight: 500; }
  .t-sub { font-size: 0.78rem; color: var(--color-fg-muted); }

  /* Tactile toggle */
  .toggle {
    appearance: none;
    width: 34px;
    height: 20px;
    border-radius: 999px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border-strong);
    position: relative;
    cursor: pointer;
    transition: background 200ms ease, border-color 200ms ease;
  }
  .toggle::before {
    content: "";
    position: absolute;
    top: 1px;
    left: 1px;
    width: 16px;
    height: 16px;
    border-radius: 50%;
    background: var(--color-page);
    box-shadow: 0 1px 2px rgba(0,0,0,0.15);
    transition: transform 240ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .toggle:checked {
    background: var(--color-fg);
    border-color: var(--color-fg);
  }
  .toggle:checked::before {
    transform: translateX(14px);
  }
</style>
