<script lang="ts">
  /**
   * AppRail — vertical primary rail (56px).
   *
   * Top → bottom: workspace switcher tile, main section buttons
   * (Create / Kanban), hairline divider, package avatars, flex spacer,
   * bottom-pinned utility tabs (Network / Settings), account button.
   *
   * Navigation is programmatic via the router instance passed from the
   * shell. The active section is read back off `router.route.name` so
   * the rail highlight tracks the URL (deep links + back/forward stay in
   * sync). Presentational beyond that — workspace/package data comes
   * from the mocked stores.
   */
  import { Plus, User as UserIcon } from "@lucide/svelte";
  import type { IRouter } from "@dvcol/svelte-simple-router/models";
  import type { Component } from "svelte";
  import { Kanban, Network as NetworkIcon, Settings as SettingsIcon, Plus as CreateIcon } from "@lucide/svelte";
  import { iconAccent, accentFill, isImageIcon } from "$lib/iconAccent.svelte";
  import { auth } from "$lib/auth.svelte";
  import { chrome } from "$lib/chrome.svelte";
  import AccountMenu from "./AccountMenu.svelte";

  let { router }: { router: IRouter } = $props();

  // Cross-component nav requests (e.g. a settings deep-link) land here:
  // the rail owns the router prop, so it consumes + clears the request.
  $effect(() => {
    const req = chrome.requestedSection;
    if (!req) return;
    chrome.requestedSection = null;
    chrome.mode = "app";
    void router.push({ name: req });
  });

  // Account menu — anchored off the bottom-pinned account button. The
  // button toggles it; the menu's contents adapt to auth state.
  let accountMenuOpen = $state(false);
  let accountBtnEl = $state<HTMLButtonElement>();

  function toggleAccountMenu() {
    if (auth.status === "checking") return;
    accountMenuOpen = !accountMenuOpen;
  }
  function closeAccountMenu() {
    accountMenuOpen = false;
  }
  function onWindowClick(e: MouseEvent) {
    if (!accountMenuOpen) return;
    const t = e.target as Node;
    if (accountBtnEl?.contains(t)) return;
    if (document.querySelector("[data-account-menu]")?.contains(t)) return;
    closeAccountMenu();
  }
  function onWindowKey(e: KeyboardEvent) {
    if (e.key === "Escape") closeAccountMenu();
  }

  type RailTab = { name: string; label: string; icon: Component };
  const topTabs: RailTab[] = [
    { name: "create", label: "Create", icon: CreateIcon },
    { name: "kanban", label: "Kanban", icon: Kanban },
  ];
  const bottomTabs: RailTab[] = [
    { name: "network", label: "Network", icon: NetworkIcon },
    { name: "settings", label: "Settings", icon: SettingsIcon },
  ];

  // Mock workspace + packages — wired to the stores later.
  const workspace = { name: "Personal", icon: "🗂️" };
  const packages = [{ id: "sandbox", name: "Sandbox", icon: "📦", active: true }];

  // The rail highlight tracks the URL, but only while the main area is
  // in app mode — a focused document tab dims the section buttons.
  const routeName = $derived((router.route?.name as string | undefined) ?? "create");
  const activeName = $derived(chrome.mode === "app" ? routeName : null);

  function go(name: string) {
    chrome.mode = "app";
    void router.push({ name });
  }

  // Clicking a package avatar: an inactive package activates + opens its
  // file drawer; the already-active package toggles the drawer.
  function onPackage(p: { id: string; active: boolean }) {
    if (p.active) chrome.toggleFiles();
    else chrome.openFiles();
    // TODO(stores): commands.packageSetActive({ name: p.id }) when wired.
  }

  function initials(name: string): string {
    const words = name.trim().split(/[\s\-_]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return (name || "?").slice(0, 2).toUpperCase();
  }

  const wsAccent = $derived(iconAccent(workspace.icon));
  function tileStyle(icon: string, accent: string | null): string {
    if (!accent || isImageIcon(icon)) return "";
    return `border-color: ${accent}; background: ${accentFill(accent)};`;
  }

  function accountInitial(): string {
    const u = auth.user;
    if (!u) return "";
    return ((u.displayName?.trim() || u.email)?.[0] ?? "?").toUpperCase();
  }
</script>

<nav class="rail" aria-label="Primary">
  <button
    class="ws"
    style={tileStyle(workspace.icon, wsAccent)}
    title={workspace.name}
    aria-label="Switch workspace"
  >
    {#if isImageIcon(workspace.icon)}
      <img src={workspace.icon} alt="" />
    {:else if workspace.icon}
      <span class="glyph">{workspace.icon}</span>
    {:else}
      <span class="ini">{initials(workspace.name)}</span>
    {/if}
  </button>

  {#each topTabs as t (t.name)}
    {@const Icon = t.icon}
    <button
      class="tab"
      class:active={activeName === t.name}
      title={t.label}
      aria-label={t.label}
      onclick={() => go(t.name)}
    >
      <Icon size={18} strokeWidth={1.8} />
    </button>
  {/each}

  <div class="divider"></div>

  {#each packages as p (p.id)}
    {@const acc = iconAccent(p.icon)}
    <button
      class="pkg"
      class:active={p.active && chrome.leftPanel === "files"}
      style={tileStyle(p.icon, acc)}
      title={p.name}
      aria-label={p.name}
      onclick={() => onPackage(p)}
    >
      {#if isImageIcon(p.icon)}
        <img src={p.icon} alt="" />
      {:else if p.icon}
        <span class="glyph">{p.icon}</span>
      {:else}
        <span class="ini">{initials(p.name)}</span>
      {/if}
    </button>
  {/each}

  <button class="tab add" title="New package" aria-label="New package">
    <Plus size={16} strokeWidth={2} />
  </button>

  <div class="spacer"></div>

  {#each bottomTabs as t (t.name)}
    {@const Icon = t.icon}
    <button
      class="tab"
      class:active={activeName === t.name}
      title={t.label}
      aria-label={t.label}
      onclick={() => go(t.name)}
    >
      <Icon size={18} strokeWidth={1.8} />
    </button>
  {/each}

  <button
    bind:this={accountBtnEl}
    class="account"
    class:signed={auth.signedIn}
    title={auth.signedIn ? (auth.user?.email ?? "Account") : "Sign in"}
    aria-label="Account"
    aria-haspopup="menu"
    aria-expanded={accountMenuOpen}
    disabled={auth.status === "checking"}
    onclick={toggleAccountMenu}
  >
    {#if auth.signedIn}
      <span class="ini">{accountInitial()}</span>
    {:else}
      <UserIcon size={15} strokeWidth={1.8} />
    {/if}
  </button>

  {#if accountMenuOpen}
    <AccountMenu onclose={closeAccountMenu} />
  {/if}
</nav>

<svelte:window onclick={onWindowClick} onkeydown={onWindowKey} />

<style>
  .rail {
    width: 56px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.35rem;
    padding: 0.85rem 0 1rem;
    background: var(--color-surface);
    border-right: 1px solid var(--color-border);
    position: relative;
    overflow: visible;
  }
  .ws {
    width: 34px;
    height: 34px;
    border-radius: 9px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    display: grid;
    place-items: center;
    cursor: pointer;
    overflow: hidden;
    padding: 0;
  }
  .ws img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .tab {
    width: 36px;
    height: 36px;
    border-radius: 10px;
    border: 1px solid transparent;
    background: transparent;
    color: var(--color-fg-muted);
    display: grid;
    place-items: center;
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease;
  }
  .tab:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .tab.active {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .tab.add {
    color: var(--color-fg-subtle);
  }
  .divider {
    width: 24px;
    height: 1px;
    background: var(--color-border);
    margin: 0.2rem 0;
  }
  .pkg {
    width: 28px;
    height: 28px;
    border-radius: 8px;
    border: 1px solid transparent;
    background: transparent;
    display: grid;
    place-items: center;
    cursor: pointer;
    overflow: hidden;
    padding: 0;
    font-size: 0.95rem;
  }
  .pkg.active {
    background: var(--color-surface-soft);
    box-shadow: 0 0 0 1px var(--color-border-strong);
  }
  .pkg img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .spacer {
    flex: 1 1 auto;
  }
  .account {
    width: 28px;
    height: 28px;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    display: grid;
    place-items: center;
    cursor: pointer;
    margin-top: 0.35rem;
  }
  .account.signed {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: transparent;
  }
  .glyph {
    font-size: 1rem;
    line-height: 1;
  }
  .ini {
    font-size: 0.7rem;
    font-weight: 600;
  }
</style>
