<script lang="ts">
  /**
   * AvatarMenu — your avatar in the top-right corner. Click opens a
   * dropdown with Profile / Settings / Sign out. Universal pattern from
   * every social app; pulls Profile + Settings out of the primary nav
   * so the chip rail can stay focused on networks.
   */
  import { User, GearSix as SettingsIcon, SignOut as LogOut } from "phosphor-svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import Avatar from "./Avatar.svelte";

  let {
    handle = null,
    onnavigate,
  }: {
    /** Current user's handle. null when not connected — the trigger
     *  renders as a placeholder avatar; the menu shows "Connect first"
     *  copy instead of profile/settings. */
    handle?: string | null;
    onnavigate: (target: "profile" | "settings") => void;
  } = $props();

  let open = $state(false);
  let trigger: HTMLButtonElement | null = $state(null);

  function close() { open = false; }

  function onWinClick(e: MouseEvent) {
    if (!open) return;
    const t = e.target as Node;
    if (trigger?.contains(t)) return;
    const menu = document.querySelector("[data-avatar-menu]");
    if (menu && menu.contains(t)) return;
    close();
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") close();
  }
</script>

<svelte:window onclick={onWinClick} onkeydown={onKey} />

<div class="wrap">
  <button
    type="button"
    class="trigger"
    aria-haspopup="menu"
    aria-expanded={open}
    bind:this={trigger}
    onclick={() => (open = !open)}
  >
    <Avatar
      handle={handle ?? "?"}
      avatar={null}
      size="sm"
      verified={false}
    />
  </button>

  {#if open}
    <div
      class="menu"
      role="menu"
      data-avatar-menu
      transition:fly={{ y: -4, duration: 160, easing: cubicOut }}
    >
      <div class="header">
        <Avatar handle={handle ?? "?"} avatar={null} size="md" verified={false} />
        <div class="header-text">
          <span class="handle">{handle ? `@${handle}` : "Not connected"}</span>
          <span class="name">{handle ? "" : "Click Connect to bind an identity."}</span>
        </div>
      </div>
      <div class="divider"></div>
      <button
        type="button"
        class="item"
        role="menuitem"
        onclick={() => { close(); onnavigate("profile"); }}
      >
        <User weight="fill" size={14} />
        Your profile
      </button>
      <button
        type="button"
        class="item"
        role="menuitem"
        onclick={() => { close(); onnavigate("settings"); }}
      >
        <SettingsIcon weight="fill" size={14} />
        Settings
      </button>
      <div class="divider"></div>
      <button type="button" class="item subtle" role="menuitem" onclick={close}>
        <LogOut weight="fill" size={14} />
        Sign out
      </button>
    </div>
  {/if}
</div>

<style>
  .wrap { position: relative; }
  .trigger {
    display: inline-flex;
    align-items: center;
    background: transparent;
    border: 0;
    padding: 0;
    cursor: pointer;
    border-radius: 50%;
    transition: transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .trigger:hover { transform: scale(1.04); }

  .menu {
    position: absolute;
    top: calc(100% + 8px);
    right: 0;
    min-width: 220px;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 6px;
    z-index: 50;
  }
  .header {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 8px 8px 10px;
  }
  .header-text { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
  .handle { font-size: 0.86rem; font-weight: 600; letter-spacing: -0.01em; }
  .name { font-size: 0.75rem; color: var(--color-fg-muted); }

  .divider {
    height: 1px;
    background: var(--color-border);
    margin: 4px 0;
  }
  .item {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    padding: 7px 10px;
    border: 0;
    background: transparent;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.82rem;
    text-align: left;
    cursor: pointer;
    border-radius: 8px;
    transition: background 120ms ease;
  }
  .item:hover { background: var(--color-surface-soft); }
  .item.subtle { color: var(--color-fg-muted); }
</style>
