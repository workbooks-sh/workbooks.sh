<script lang="ts">
  /**
   * AppRail — vertical primary rail.
   *
   * Layout, top to bottom (see docs/canonical-model.md):
   *   1. Workspace switcher — click opens the WorkspaceSwitcher popover.
   *      Shows the active workspace's emoji (or initials fallback).
   *   2. Main section buttons (Chat / Kanban / Settings).
   *   3. Hairline divider.
   *   4. Package avatars — one per package in the active workspace.
   *      Click an inactive package → make active + open file drawer.
   *      Click the active package → toggle drawer.
   *   5. "+ New package" button — invokes the parent's create handler.
   *
   * Presentational. Parent (+page.svelte) owns the data + the popover.
   */
  import { Plus, LogIn, LogOut, RefreshCw, User as UserIcon } from "@lucide/svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { invoke } from "@tauri-apps/api/core";
  import RailTooltip from "./RailTooltip.svelte";
  import FolderIcon from "$lib/ui/FolderIcon.svelte";
  import { iconAccent, accentFill, isImageIcon } from "$lib/ui/iconAccent.svelte";
  import { auth } from "$lib/auth/store.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";

  export type RailTab = {
    id: string;
    label: string;
    icon: typeof import("@lucide/svelte").MessagesSquare;
  };

  export type RailPackage = {
    id: string;
    name: string;
    isActive: boolean;
    /** Single emoji / glyph / data-URL image. Empty = fall back to
     *  computed initials. Same single-field model as Workspace. */
    icon?: string;
  };

  let {
    tabs,
    bottomTabs = [],
    active = $bindable(),
    packages = [],
    workspaceName = "",
    workspaceIcon = "",
    filesOpen = false,
    onToggleFiles,
    onSwitchWorkspace,
    onSelectPackage,
    onCreatePackageMenu,
    onWorkspaceContext,
    onPackageContext,
  }: {
    tabs: RailTab[];
    /** Tabs rendered in a bottom-pinned section after a flex spacer.
     *  Used for utility surfaces (Settings, GitHub, etc.) so they sit
     *  visually separate from the main app sections + packages. */
    bottomTabs?: RailTab[];
    active: string;
    packages?: RailPackage[];
    workspaceName?: string;
    workspaceIcon?: string;
    filesOpen?: boolean;
    onToggleFiles?: () => void;
    onSwitchWorkspace?: (anchor: HTMLElement) => void;
    onSelectPackage?: (id: string) => void;
    onCreatePackageMenu?: (rect: DOMRect) => void;
    onWorkspaceContext?: (x: number, y: number) => void;
    onPackageContext?: (id: string, x: number, y: number) => void;
  } = $props();

  function initials(name: string): string {
    const words = name.trim().split(/[\s\-_]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return (name || "?").slice(0, 2).toUpperCase();
  }

  // Click an inactive package → make active + open files drawer.
  // Click an already-active package → toggle the files drawer.
  function handlePackage(p: RailPackage) {
    if (p.isActive) {
      onToggleFiles?.();
    } else {
      if (!filesOpen) onToggleFiles?.();
      onSelectPackage?.(p.id);
    }
  }

  // Accent styling — derive a solid stroke + faint fill from the icon's
  // highest-saturation pixel. Skipped for full-bleed images (the image
  // already covers the tile so a colored border would be redundant /
  // ugly), and falls through to default styling when the helper can't
  // find a saturated pixel (grayscale glyph, empty icon → initials).
  const wsAccent = $derived(iconAccent(workspaceIcon));
  function tileStyle(icon: string, accent: string | null): string {
    if (!accent || isImageIcon(icon)) return "";
    return `border-color: ${accent}; background: ${accentFill(accent)};`;
  }

  let switchBtnEl: HTMLButtonElement | undefined = $state();

  // ── Account button (anonymous → signed-in avatar) ──────────────────
  // Pinned below bottomTabs. Reads directly from the app-level auth
  // store — same source as the sign-in overlay + Account settings, so
  // every entry point reflects the same state. Click: signed-out →
  // start sign-in; signed-in → open a small menu with sign-out.
  let accountMenuOpen = $state(false);
  let accountBtnEl: HTMLButtonElement | undefined = $state();
  let accountBusy = $state(false);

  function accountInitial(): string {
    const u = auth.user;
    if (!u) return "";
    const src = u.displayName?.trim() || u.email;
    return (src?.[0] ?? "?").toUpperCase();
  }

  function closeAccountMenu() {
    accountMenuOpen = false;
  }

  // Toggle the menu on every click — the menu's own contents adapt
  // to the current auth state (sign-in CTA when signed-out, sign-out
  // when signed-in, restart when sidecar-offline). User asked for a
  // single "click the avatar" entry point that always shows a panel
  // with what's running.
  function handleAccountClick() {
    if (auth.status === "checking") return;
    accountMenuOpen = !accountMenuOpen;
  }

  async function doSignIn() {
    if (accountBusy) return;
    accountBusy = true;
    try {
      closeAccountMenu();
      await auth.signIn();
    } catch {
      // signIn surfaces errors on its own via lastError
    } finally {
      accountBusy = false;
    }
  }

  async function handleSignOut() {
    closeAccountMenu();
    accountBusy = true;
    try {
      await auth.signOut();
    } finally {
      accountBusy = false;
    }
  }

  // Clear local sign-in state when the cookie is stale (e.g., after
  // a cookie-attribute migration like SameSite=Lax→None or a session
  // expiry the broker can't recover from). Calls the broker's
  // sign-out endpoint (best effort — it issues a Max-Age=0 cookie)
  // then forces the auth store to re-probe. If the broker is
  // unreachable we still drop local state so the next sign-in click
  // is unblocked.
  let resetting = $state(false);
  async function resetLocalSession() {
    if (resetting) return;
    resetting = true;
    closeAccountMenu();
    try {
      await auth.signOut();
    } finally {
      resetting = false;
    }
  }

  async function restartEngine() {
    if (accountBusy) return;
    accountBusy = true;
    try {
      try {
        await invoke("sidecar_restart");
      } catch {
        /* ignore — refresh below reflects new state regardless */
      }
      await auth.refresh();
    } finally {
      accountBusy = false;
    }
  }

  // Status-row helpers — keep the labels short + scannable.
  const sidecarStatus = $derived.by(() => {
    const s = sidecar.status.state;
    if (s === "ready") return { label: "Running", dot: "ok" as const };
    if (s === "starting" || s === "restarting")
      return { label: "Starting…", dot: "pending" as const };
    if (s === "unhealthy") return { label: "Unhealthy", dot: "warn" as const };
    if (s === "crashed") return { label: "Crashed", dot: "err" as const };
    return { label: "Stopped", dot: "err" as const };
  });
  const accountRow = $derived.by(() => {
    if (auth.status === "signed-in")
      return { label: "Signed in", dot: "ok" as const };
    if (auth.status === "sidecar-offline")
      return { label: "Unavailable", dot: "warn" as const };
    if (auth.status === "checking")
      return { label: "Checking…", dot: "pending" as const };
    return { label: "Not signed in", dot: "idle" as const };
  });
  const identityRow = $derived.by(() => {
    if (auth.identity?.handle)
      return { label: `@${auth.identity.handle}`, dot: "ok" as const };
    if (auth.status === "signed-in")
      return { label: "Not connected", dot: "idle" as const };
    return { label: "—", dot: "idle" as const };
  });

  function handleMenuKey(e: KeyboardEvent) {
    if (e.key === "Escape" && accountMenuOpen) closeAccountMenu();
  }

  function onWindowClick(e: MouseEvent) {
    if (!accountMenuOpen) return;
    const t = e.target as Node;
    if (accountBtnEl?.contains(t)) return;
    const menu = document.querySelector("[data-account-menu]");
    if (menu && menu.contains(t)) return;
    closeAccountMenu();
  }
</script>

<svelte:window onclick={onWindowClick} onkeydown={handleMenuKey} />

<div class="rail-host">
  <nav class="rail" aria-label="Primary">
    <RailTooltip label={workspaceName || "Workspace"}>
      <button
        type="button"
        class="workspace-switch"
        class:has-image={workspaceIcon.startsWith("data:image/")}
        class:has-accent={!!wsAccent && !isImageIcon(workspaceIcon)}
        aria-label="Switch workspace ({workspaceName || 'none'})"
        bind:this={switchBtnEl}
        style={tileStyle(workspaceIcon, wsAccent)}
        onclick={() => switchBtnEl && onSwitchWorkspace?.(switchBtnEl)}
        oncontextmenu={(e) => {
          e.preventDefault();
          onWorkspaceContext?.(e.clientX, e.clientY);
        }}
      >
        {#if workspaceIcon.startsWith("data:image/")}
          <img class="ws-img" src={workspaceIcon} alt="" />
        {:else if workspaceIcon}
          <span class="ws-icon">{workspaceIcon}</span>
        {:else}
          <span class="ws-initials">{initials(workspaceName)}</span>
        {/if}
      </button>
    </RailTooltip>

    {#each tabs as tab (tab.id)}
      {@const Icon = tab.icon}
      <RailTooltip label={tab.label}>
        <button
          type="button"
          class="rail-btn"
          class:active={active === tab.id}
          aria-label={tab.label}
          aria-pressed={active === tab.id}
          onclick={() => (active = tab.id)}
        >
          <Icon size={18} strokeWidth={1.8} aria-hidden="true" />
        </button>
      </RailTooltip>
    {/each}

    {#if packages.length > 0 || onCreatePackageMenu}
      <div class="hairline" aria-hidden="true"></div>
    {/if}

    {#each packages as pkg (pkg.id)}
      <RailTooltip label={pkg.name}>
        <button
          type="button"
          class="rail-btn pkg"
          class:active={pkg.isActive}
          aria-label={pkg.name}
          aria-pressed={pkg.isActive}
          onclick={() => handlePackage(pkg)}
          oncontextmenu={(e) => {
            e.preventDefault();
            onPackageContext?.(pkg.id, e.clientX, e.clientY);
          }}
        >
          <FolderIcon icon={pkg.icon ?? ""} size={36} />
        </button>
      </RailTooltip>
    {/each}

    {#if onCreatePackageMenu}
      <RailTooltip label="New package">
        <button
          type="button"
          class="rail-btn create"
          aria-label="Create a new package"
          onclick={(e) =>
            onCreatePackageMenu?.(e.currentTarget.getBoundingClientRect())}
        >
          <Plus size={16} strokeWidth={1.8} aria-hidden="true" />
        </button>
      </RailTooltip>
    {/if}

    <span class="bottom-spacer" aria-hidden="true"></span>

    {#if bottomTabs.length > 0}
      <div class="hairline" aria-hidden="true"></div>
      {#each bottomTabs as tab (tab.id)}
        {@const Icon = tab.icon}
        <RailTooltip label={tab.label}>
          <button
            type="button"
            class="rail-btn"
            class:active={active === tab.id}
            aria-label={tab.label}
            aria-pressed={active === tab.id}
            onclick={() => (active = tab.id)}
          >
            <Icon size={18} strokeWidth={1.8} aria-hidden="true" />
          </button>
        </RailTooltip>
      {/each}
    {/if}

    <!-- Account button — anonymous when signed-out, avatar when signed-in.
         Pinned at the very bottom; reads from $lib/auth/store. -->
    <button
      type="button"
      class="rail-btn account"
      class:account-signed-in={auth.status === "signed-in"}
      class:account-busy={accountBusy}
      bind:this={accountBtnEl}
      aria-label={
        auth.status === "signed-in"
          ? `Signed in as ${auth.user?.displayName ?? auth.user?.email ?? ""}`
          : auth.status === "signed-out"
            ? "Sign in to Workbooks"
            : auth.status === "sidecar-offline"
              ? "Workbooks isn't running"
              : "Checking sign-in status"
      }
      aria-haspopup={auth.status === "signed-in" ? "menu" : undefined}
      aria-expanded={auth.status === "signed-in" ? accountMenuOpen : undefined}
      onclick={handleAccountClick}
      disabled={auth.status === "checking" || accountBusy}
    >
      {#if auth.status === "signed-in"}
        {#if auth.user?.picture}
          <img class="account-avatar account-avatar-img" src={auth.user.picture} alt="" referrerpolicy="no-referrer" />
        {:else}
          <span class="account-avatar">{accountInitial()}</span>
        {/if}
      {:else if auth.status === "checking"}
        <span class="account-anon"></span>
      {:else if auth.status === "sidecar-offline"}
        <span class="account-anon offline">
          <RefreshCw size={13} strokeWidth={2.25} class={accountBusy ? "spinning" : ""} />
        </span>
      {:else}
        <span class="account-anon"><UserIcon size={14} strokeWidth={2} /></span>
      {/if}
    </button>

    {#if accountMenuOpen}
      <div
        class="account-menu"
        role="menu"
        data-account-menu
        transition:fly={{ x: -4, duration: 140, easing: cubicOut }}
      >
        <!-- Header: avatar + identity (signed in) OR muted "Not signed in" -->
        <div class="account-menu-head">
          {#if auth.status === "signed-in"}
            {#if auth.user?.picture}
              <img class="account-avatar lg account-avatar-img" src={auth.user.picture} alt="" referrerpolicy="no-referrer" />
            {:else}
              <span class="account-avatar lg">{accountInitial()}</span>
            {/if}
            <div class="account-menu-meta">
              {#if auth.user?.displayName}
                <span class="account-name">{auth.user.displayName}</span>
              {/if}
              <span class="account-email">{auth.user?.email}</span>
            </div>
          {:else}
            <span class="account-avatar lg muted"><UserIcon size={16} strokeWidth={2} /></span>
            <div class="account-menu-meta">
              <span class="account-name muted">Not signed in</span>
              <span class="account-email">Workbooks works without an account — sign in to use the network.</span>
            </div>
          {/if}
        </div>

        <div class="account-menu-divider"></div>

        <!-- Status rows — what's running, scannable in a glance. -->
        <div class="status-block">
          <div class="status-row">
            <span class="status-dot dot-{sidecarStatus.dot}"></span>
            <span class="status-label">Engine</span>
            <span class="status-val">{sidecarStatus.label}</span>
          </div>
          <div class="status-row">
            <span class="status-dot dot-{accountRow.dot}"></span>
            <span class="status-label">Account</span>
            <span class="status-val">{accountRow.label}</span>
          </div>
          <div class="status-row">
            <span class="status-dot dot-{identityRow.dot}"></span>
            <span class="status-label">Network ID</span>
            <span class="status-val">{identityRow.label}</span>
          </div>
        </div>

        <div class="account-menu-divider"></div>

        <!-- Actions adapt to state. -->
        {#if auth.status === "signed-in"}
          <button
            type="button"
            class="account-menu-item"
            role="menuitem"
            onclick={handleSignOut}
            disabled={accountBusy}
          >
            <LogOut size={13} strokeWidth={2} />
            Sign out
          </button>
        {:else if auth.status === "signed-out"}
          <button
            type="button"
            class="account-menu-item"
            role="menuitem"
            onclick={doSignIn}
            disabled={accountBusy}
          >
            <LogIn size={13} strokeWidth={2} />
            {accountBusy ? "Opening sign-in…" : "Sign in to Workbooks"}
          </button>
          <!-- Always-available escape hatch when a stale cookie blocks
               re-authentication. Calls broker /sign-out (best effort)
               then forces the auth store back to its checking baseline. -->
          <button
            type="button"
            class="account-menu-item subtle"
            role="menuitem"
            onclick={resetLocalSession}
            disabled={resetting}
          >
            <RefreshCw size={13} strokeWidth={2} class={resetting ? "spinning" : ""} />
            {resetting ? "Resetting…" : "Reset local sign-in"}
          </button>
        {/if}

        {#if sidecar.status.state !== "ready" && sidecar.status.state !== "starting"}
          <button
            type="button"
            class="account-menu-item"
            role="menuitem"
            onclick={restartEngine}
            disabled={accountBusy}
          >
            <RefreshCw size={13} strokeWidth={2} class={accountBusy ? "spinning" : ""} />
            Restart engine
          </button>
        {/if}
      </div>
    {/if}
  </nav>
</div>

<style>
  .rail-host {
    flex-shrink: 0;
    width: 56px;
    position: relative;
    z-index: 100;
  }
  .rail {
    width: 56px;
    height: 100%;
    min-height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.35rem;
    padding: 0.85rem 0 1rem;
    background: var(--color-surface);
    border-right: 1px solid var(--color-border);
    position: sticky;
    top: 36px;
    z-index: 100;
    overflow: visible;
  }

  .workspace-switch {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    margin-bottom: 0.5rem;
    border-radius: 9px;
    border: 0;
    background: var(--color-fg);
    color: var(--color-page);
    cursor: pointer;
    transition: opacity 0.12s, transform 0.08s;
  }
  .workspace-switch:hover { opacity: 0.88; }
  .workspace-switch:active { transform: scale(0.96); }
  .workspace-switch.has-image {
    background: transparent;
    overflow: hidden;
    /* No border on image tiles — image carries the visual weight.
     * Removed 2026-05-27 per user preference for cleaner rail. */
  }
  /* Accent class still applied by tileStyle() but visually neutralised
   * here — the inline border-color + background from tileStyle has
   * effect only when these properties exist, so by zeroing them in
   * CSS we keep the accent computation around (cheap to re-enable)
   * while presenting a plain unbordered icon. */
  .workspace-switch.has-accent {
    border: 0;
    background: transparent !important;
    color: var(--color-fg);
  }
  .ws-initials {
    font-size: 12px;
    font-weight: 600;
    letter-spacing: 0.02em;
  }
  .ws-icon { font-size: 18px; line-height: 1; }
  .ws-img { width: 100%; height: 100%; object-fit: cover; display: block; }

  .rail-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    height: 36px;
    width: 36px;
    border-radius: 10px;
    color: var(--color-fg-muted);
    background: transparent;
    border: 0;
    padding: 0;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }
  .rail-btn:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .rail-btn.active {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  /* Packages render as folders (FolderIcon); the active ring lives on the
   * parent .rail-btn. */
  .rail-btn.pkg { color: var(--color-fg); }

  .rail-btn.create { color: var(--color-fg-muted); }
  .rail-btn.create:hover { color: var(--color-fg); }

  .hairline {
    width: 24px;
    height: 1px;
    background: var(--color-border);
    margin: 0.4rem 0;
  }
  /* Flex spacer that pushes the bottom-pinned tabs (Settings, GitHub
   * stub, etc.) to the bottom of the rail. */
  .bottom-spacer {
    flex: 1 1 auto;
    min-height: 0.4rem;
  }

  /* Account button — anonymous icon when signed-out, monogram avatar
     when signed-in. Pinned below the bottomTabs. */
  .rail-btn.account {
    margin-top: 0.25rem;
    position: relative;
  }
  .account-anon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: var(--color-surface-soft);
    border: 1px dashed var(--color-border);
    color: var(--color-fg-muted);
  }
  .account-anon.offline {
    border-style: solid;
    border-color: rgba(220, 130, 30, 0.45);
    color: rgb(190, 110, 25);
  }
  .account-avatar {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0.02em;
    border: 1px solid var(--color-fg);
  }
  .account-avatar.lg {
    width: 36px;
    height: 36px;
    font-size: 14px;
  }
  .account-avatar-img {
    object-fit: cover;
    /* Photo overrides the initials-tile background + monogram color. */
    background: var(--color-surface-soft);
    color: transparent;
  }
  .rail-btn.account.account-signed-in {
    /* No hover bg — the avatar tile carries its own affordance. */
  }
  :global(.spinning) {
    animation: spin 900ms linear infinite;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* Popover anchored to the right of the rail's bottom-left corner. */
  .account-menu {
    position: absolute;
    left: calc(100% + 6px);
    bottom: 0.85rem;
    min-width: 220px;
    padding: 8px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    box-shadow: 0 6px 22px rgba(15, 15, 15, 0.10);
    z-index: 200;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .account-menu-head {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 8px 8px;
  }
  .account-menu-meta {
    display: flex;
    flex-direction: column;
    min-width: 0;
    gap: 1px;
  }
  .account-name {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--color-fg);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .account-email {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .account-menu-divider {
    height: 1px;
    background: var(--color-border);
    margin: 2px 0;
  }
  .account-avatar.muted {
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .account-name.muted { color: var(--color-fg-muted); font-weight: 500; }

  /* Status dashboard — three rows, label left + value right with a
     colored dot indicator. */
  .status-block {
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 4px 0;
  }
  .status-row {
    display: grid;
    grid-template-columns: 8px 1fr auto;
    align-items: center;
    gap: 8px;
    padding: 4px 10px;
  }
  .status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--color-fg-muted);
  }
  .status-dot.dot-ok      { background: rgb(34, 160, 105); }
  .status-dot.dot-pending { background: rgb(220, 165, 30); animation: pulse 1200ms ease-in-out infinite; }
  .status-dot.dot-warn    { background: rgb(220, 130, 30); }
  .status-dot.dot-err     { background: rgb(220, 60, 60); }
  .status-dot.dot-idle    { background: var(--color-fg-muted); opacity: 0.45; }
  .status-label {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    text-transform: uppercase;
    letter-spacing: 0.03em;
    font-weight: 600;
  }
  .status-val {
    font-size: 0.78rem;
    color: var(--color-fg);
    font-weight: 500;
    max-width: 130px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  @keyframes pulse {
    0%, 100% { opacity: 0.55; }
    50%      { opacity: 1; }
  }
  .account-menu-item {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 7px 10px;
    border-radius: 6px;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.84rem;
    text-align: left;
    cursor: pointer;
  }
  .account-menu-item:hover:not(:disabled) {
    background: var(--color-surface-soft);
  }
  .account-menu-item:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }
  /* Reset-local-sign-in: visually secondary so it doesn't compete
     with the primary Sign-in CTA above it. */
  .account-menu-item.subtle {
    color: var(--color-fg-muted);
    font-size: 0.78rem;
  }
  .account-menu-item.subtle:hover:not(:disabled) {
    color: var(--color-fg);
  }
</style>
