<script lang="ts">
  import {
    GearSix as SettingsIcon,
    ShareNetwork as NetworkIcon,
  } from "phosphor-svelte";
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import Sidebar, {
    type RailTab,
    type RailPackage,
  } from "$lib/components/Sidebar.svelte";
  import SettingsContainer from "$lib/components/settings/SettingsContainer.svelte";
  import AgentPanel from "$lib/components/AgentPanel.svelte";
  import HomePanel from "$lib/home/HomePanel.svelte";
  import PackageTreeDrawer from "$lib/components/PackageTreeDrawer.svelte";
  import BoardPanel from "$lib/board/BoardPanel.svelte";
  import { FolderOpen, Plus as PlusIcon } from "phosphor-svelte";
  import CreatePackageModal from "$lib/home/CreatePackageModal.svelte";
  import { createPackage } from "$lib/home/createPackage.svelte";
  import TerminalDrawer from "$lib/components/TerminalDrawer.svelte";
  import NetworkPanel from "$lib/network/NetworkPanel.svelte";
  import DocViewer from "$lib/viewer/DocViewer.svelte";
  import DropOverlay from "$lib/viewer/DropOverlay.svelte";
  import ToastStack from "$lib/components/ToastStack.svelte";
  import WorkspaceOnboarding from "$lib/workspace/WorkspaceOnboarding.svelte";
  import KeychainOnboarding from "$lib/setup/KeychainOnboarding.svelte";
  import EngineOnboarding from "$lib/setup/EngineOnboarding.svelte";
  import { setupStatus } from "$lib/bridge/setup.svelte";
  import { engineStatus } from "$lib/bridge/engine.svelte";
  import WorkspaceSwitcher from "$lib/workspace/WorkspaceSwitcher.svelte";
  import EditNameModal from "$lib/workspace/EditNameModal.svelte";
  import EditIconModal from "$lib/workspace/EditIconModal.svelte";
  import ContextMenu from "$lib/components/ContextMenu.svelte";
  import SearchDrawer from "$lib/components/SearchDrawer.svelte";
  import BookmarksPopover from "$lib/components/BookmarksPopover.svelte";
  import { bookmarks } from "$lib/bridge/bookmarks.svelte";
  import { themes } from "$lib/bridge/themes.svelte";
  import { PencilSimple as Pencil, Smiley as Smile, Trash as Trash2 } from "phosphor-svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { wizard } from "$lib/setup/wizard.svelte";
  import { ws } from "$lib/bridge/ws.svelte";
  import { tabs } from "$lib/tabs/store.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { docIcons } from "$lib/ui/docIcon.svelte";
  import { terminalDrawer } from "$lib/bridge/terminal.svelte";

  /* Sidebar sections. Create is the branded CTA above the bottom nav
   * (not a plain row); Network/Settings are bottom-pinned utility rows. */
  const bottomRailTabs: RailTab[] = [
    { id: "network", label: "Network", icon: NetworkIcon },
    { id: "settings", label: "Settings", icon: SettingsIcon },
  ];
  const sectionLabels: Record<string, string> = {
    home: "Create",
    network: "Network",
    settings: "Settings",
    kanban: "Kanban",
  };

  let active = $state("home");
  let lastRail = $state("home");

  // Onboarding gate — first launch only. The desktop install IS the
  // monorepo root; without at least one Workspace it has nowhere to
  // hang Packages.
  //
  // Two-stage gate: keychain setup splash FIRST (so the OS keychain
  // prompt fires with context, not as a boot-time surprise), then
  // workspace onboarding. Each stage is non-dismissable; user has
  // to click through.
  // OFFLINE-FIRST: the app boots and is usable WITHOUT the engine (the
  // workbook-native local tier needs no server). Engine state is surfaced in
  // the titlebar, never as a blocking gate. So `initialized` starts true and the
  // setup/onboarding splashes never block boot — they become opt-in flows later
  // (Phase B), not a boot wall that hangs when a backend command is missing.
  let initialized = $state(true);
  let engineInstalled = $state(true);
  let keychainInitialized = $state(true);
  const showEngineSetup = false;
  const showKeychainSetup = false;
  const showOnboarding = false;

  // Switcher popover state — anchor element + open flag.
  let switcherAnchor = $state<HTMLElement | null>(null);
  let switcherOpen = $state(false);

  // Context-menu state. Two distinct menus (workspace + package) share
  // the same primitive; only one is open at a time.
  let wsMenuOpen = $state(false);
  let wsMenuX = $state(0);
  let wsMenuY = $state(0);

  let pkgMenuOpen = $state(false);
  let pkgMenuX = $state(0);
  let pkgMenuY = $state(0);
  let pkgMenuTarget = $state<string | null>(null);

  // Modal state for rename / icon-change. Driven from context menu items.
  type ModalKind = "ws-rename" | "ws-icon" | "pkg-rename" | null;
  let modal = $state<ModalKind>(null);
  let modalBusy = $state(false);
  let modalError = $state<string | null>(null);

  function onWorkspaceContext(x: number, y: number) {
    wsMenuX = x;
    wsMenuY = y;
    wsMenuOpen = true;
  }

  function onPackageContext(id: string, x: number, y: number) {
    pkgMenuTarget = id;
    pkgMenuX = x;
    pkgMenuY = y;
    pkgMenuOpen = true;
  }

  // Workspace context-menu actions.
  function wsRenameClick() {
    wsMenuOpen = false;
    modalError = null;
    modal = "ws-rename";
  }
  function wsIconClick() {
    wsMenuOpen = false;
    modalError = null;
    modal = "ws-icon";
  }
  async function wsDeleteClick() {
    wsMenuOpen = false;
    const a = workspaces.active;
    if (!a) return;
    const ok = await tauriConfirm(`Delete workspace "${a.name}"? Packages stay on disk.`, { kind: "warning" });
    if (!ok) return;
    try {
      await workspaces.delete(a.id);
    } catch (e) {
      console.warn("[ws] delete failed", e);
    }
  }

  async function commitWsRename(name: string) {
    const a = workspaces.active;
    if (!a) return;
    modalBusy = true;
    modalError = null;
    try {
      await workspaces.rename(a.id, name);
      modal = null;
    } catch (e) {
      modalError = e instanceof Error ? e.message : String(e);
    } finally {
      modalBusy = false;
    }
  }
  async function commitWsIcon(icon: string) {
    const a = workspaces.active;
    if (!a) return;
    try {
      await workspaces.setIcon(a.id, icon);
    } catch (e) {
      modalError = e instanceof Error ? e.message : String(e);
    }
  }

  // Package context-menu actions.
  function pkgRenameClick() {
    pkgMenuOpen = false;
    modalError = null;
    modal = "pkg-rename";
  }
  async function pkgDeleteClick() {
    pkgMenuOpen = false;
    const id = pkgMenuTarget;
    const a = workspaces.active;
    if (!id || !a) return;
    const ok = await tauriConfirm(
      `Remove "${id}" from the rail? The folder stays on disk; only the workspace binding is dropped.`,
      { kind: "warning" },
    );
    if (!ok) return;
    try {
      await workspaces.removePackage(a.id, id);
      // Also drop the package definition itself (the Rust workspace_*).
      await packageStore.delete(id);
    } catch (e) {
      console.warn("[pkg] delete failed", e);
    }
  }
  async function commitPkgRename(name: string) {
    // Rust workspace.rs doesn't expose a rename — for v1, the user has
    // to delete + re-create. Surface that nicely.
    modalError = "Package rename isn't supported yet — delete and re-create with the new name.";
    modalBusy = false;
  }

  // Push the active rail label up to the titlebar.
  $effect(() => {
    chrome.section = sectionLabels[active] ?? "";
    if (active !== lastRail) {
      chrome.mode = "app";
      lastRail = active;
    }
  });

  // Cross-component nav requests (e.g. the chat header's "Edit agent"
  // menu sets chrome.requestedSection = "settings"). Consume + clear.
  $effect(() => {
    const req = chrome.requestedSection;
    if (!req) return;
    if (req in sectionLabels) {
      active = req;
      chrome.mode = "app";
    }
    chrome.requestedSection = null;
  });

  // Doc/app mode transitions follow the tabs store.
  let lastActiveId = $state<string | null>(null);
  $effect(() => {
    const cur = tabs.activeId;
    if (cur && cur !== lastActiveId) chrome.mode = "doc";
    if (!cur && tabs.tabs.length === 0) chrome.mode = "app";
    lastActiveId = cur;
  });

  // Filter the package list by the active workspace.
  const railPackages = $derived<RailPackage[]>(
    (() => {
      const ws_ = workspaces.active;
      if (!ws_) return [];
      // Order follows the workspace's package_names (the rail order the user
      // sets by dragging), filtered to packages that actually exist.
      const exists = new Set(packageStore.workspaces);
      return ws_.package_names
        .filter((name) => exists.has(name))
        .map((name) => ({
          id: name,
          name,
          isActive: packageStore.active?.name === name,
          icon: packageStore.meta[name]?.icon ?? "",
          kind: packageStore.meta[name]?.kind ?? "folder",
        }));
    })(),
  );

  // Feed the doc-icon registry: every app's workbook path gets the
  // app's stored icon, so tabs / bookmarks / folder rows all show the
  // same identity for the same document.
  $effect(() => {
    for (const p of railPackages) {
      if (p.kind !== "app" || !p.icon) continue;
      void invoke<string>("package_app_workbook", { name: p.id })
        .then((path) => docIcons.register(path, p.icon))
        .catch(() => {});
    }
  });

  async function onReorderPackages(orderedIds: string[]) {
    const ws_ = workspaces.active;
    if (!ws_) return;
    try {
      await workspaces.reorderPackages(ws_.id, orderedIds);
    } catch (e) {
      console.warn("[rail] reorder packages failed", e);
    }
  }

  // Folder click → open the folder viewer panel (select + show grid).
  async function onSelectPackage(name: string) {
    try {
      await packageStore.setActive(name);
      chrome.openFiles();
    } catch (e) {
      console.warn("[rail] setActive package failed", e);
    }
  }

  // Workbook row inside an expanded sidebar folder → open as a tab.
  async function onOpenWorkbook(path: string) {
    try {
      await tabs.open(path);
      chrome.mode = "doc";
    } catch (e) {
      console.warn("[sidebar] open workbook failed", e);
    }
  }

  // App click → open the app as a WINDOW: a new content tab via the
  // existing tab system, showing the app's workbook (mirrors how the
  // springboard grid opens a workbook in PackageGridView.open()).
  async function onOpenApp(name: string) {
    try {
      const path = await invoke<string>("package_app_workbook", { name });
      await tabs.open(path);
      chrome.mode = "doc";
    } catch (e) {
      console.warn("[rail] open app failed", e);
    }
  }

  // wb-i38o.35 — "+ New package" opens a popover anchored at the
  // button with two paths: Create new (empty package) or Import
  // folder (recursively copied into the monorepo). Mode selection
  // and folder picking are driven by `createPackage.svelte.ts`;
  // we just expose the popover trigger here.
  function onCreatePackageMenu(rect: DOMRect) {
    const wsActive = workspaces.active;
    if (!wsActive) {
      console.warn("[rail] no active workspace; cannot create package");
      return;
    }
    createPackage.openMenu(rect);
  }

  function onSwitchWorkspace(anchor: HTMLElement) {
    switcherAnchor = anchor;
    switcherOpen = !switcherOpen;
  }

  async function onOnboardingComplete() {
    await workspaces.refresh();
  }

  function onKeychainSetupComplete() {
    keychainInitialized = true;
  }

  onMount(() => {
    // After the first status snapshot, offer the engine setup wizard if no
    // engine is configured (and the user hasn't dismissed it). Offline-first:
    // it's skippable and never blocks the app.
    sidecar.init().then(() => wizard.maybeAutoOpen());
    ws.init();
    tabs.init();
    packageStore.init();
    workspaces.init().then(() => (initialized = true));
    bookmarks.init();
    themes.init();
    // Cheap, non-prompting check — reads ~/Workbooks/Engine/setup.json.
    // If the keychain marker is set, skip the splash. If not, the
    // KeychainOnboarding splash renders first.
    setupStatus()
      .then((s) => {
        keychainInitialized = s.keychain_initialized;
      })
      .catch((e) => {
        console.warn("[setup] status check failed:", e);
        // Fail-open: if we can't talk to the backend, treat as
        // initialized so the user can still use the app. Worst case
        // they see the OS prompt anyway.
        keychainInitialized = true;
      });
    // Engine install state — non-prompting probe; reads the launchd
    // plist + discovery file. Fail-open mirrors the keychain path.
    engineStatus()
      .then((s) => {
        engineInstalled = s.installed;
      })
      .catch((e) => {
        console.warn("[engine] status check failed:", e);
        engineInstalled = true;
      });
  });

  function onEngineInstallComplete() {
    engineInstalled = true;
  }

  function onKey(e: KeyboardEvent) {
    // ⌃` (or ⌘`) — toggle the terminal drawer. Mirrors VS Code's
    // shortcut. Allowed alongside Cmd because macOS users grab for
    // ⌘ first; the VS Code default is Ctrl on every platform.
    if ((e.ctrlKey || e.metaKey) && e.key === "`") {
      e.preventDefault();
      terminalDrawer.toggle();
      return;
    }

    if (!(e.metaKey || e.ctrlKey) || e.shiftKey || e.altKey) return;
    if (e.key === "k") {
      e.preventDefault();
      chrome.toggleSearch();
    } else if (e.key === "b") {
      e.preventDefault();
      chrome.toggleSidebar();
    } else if (e.key === "j") {
      e.preventDefault();
      chrome.agentOpen = !chrome.agentOpen;
    } else if (/^[1-9]$/.test(e.key)) {
      // ⌘1..⌘9 — open the bookmark in that slot, if any.
      const slot = Number(e.key);
      const b = bookmarks.bySlot(slot);
      if (b) {
        e.preventDefault();
        void tabs.open(b.path);
      }
    }
  }
</script>

<svelte:window onkeydown={onKey} />

{#if !initialized}
  <div class="loading"></div>
{:else if showEngineSetup}
  <EngineOnboarding oncomplete={onEngineInstallComplete} />
{:else if showKeychainSetup}
  <KeychainOnboarding oncomplete={onKeychainSetupComplete} />
{:else if showOnboarding}
  <WorkspaceOnboarding oncomplete={onOnboardingComplete} />
{:else}
  <div class="app">
    <div
      class="sidebar-host"
      class:closed={!chrome.sidebarOpen}
      inert={!chrome.sidebarOpen}
    >
      <Sidebar
        bottomTabs={bottomRailTabs}
        onCreate={() => (active = "home")}
        createActive={active === "home" && chrome.mode === "app"}
        bind:active
        packages={railPackages}
        workspaceName={workspaces.active?.name ?? ""}
        workspaceIcon={workspaces.active?.icon ?? ""}
        onSwitchWorkspace={onSwitchWorkspace}
        onSelectPackage={onSelectPackage}
        onOpenApp={onOpenApp}
        onOpenWorkbook={onOpenWorkbook}
        loadWorkbooks={(id) => packageStore.workbooks(id)}
        onReorderPackages={onReorderPackages}
        onCreatePackageMenu={onCreatePackageMenu}
        onWorkspaceContext={onWorkspaceContext}
        onPackageContext={onPackageContext}
      />
    </div>

    {#if chrome.leftPanel === "files"}
      <PackageTreeDrawer />
    {:else if chrome.leftPanel === "search"}
      <SearchDrawer onclose={() => chrome.closeLeft()} />
    {/if}

    <main class="main">
      <div class="main-content">
        <DropOverlay />
        {#if chrome.mode === "doc"}
          <DocViewer />
        {:else if active === "home"}
          <HomePanel />
        {:else if active === "kanban"}
          <BoardPanel />
        {:else if active === "network"}
          <NetworkPanel />
        {:else if active === "settings"}
          <SettingsContainer />
        {/if}
      </div>
      <TerminalDrawer />
    </main>

    {#if chrome.agentOpen}
      <AgentPanel />
    {/if}

    <WorkspaceSwitcher
      anchor={switcherAnchor}
      bind:open={switcherOpen}
    />

    <BookmarksPopover
      anchor={chrome.bookmarksAnchor}
      bind:open={chrome.bookmarksOpen}
    />

    <ContextMenu bind:open={wsMenuOpen} x={wsMenuX} y={wsMenuY}>
      <button class="ctx-item" onclick={wsRenameClick}>
        <Pencil size={13} weight="fill" /> Rename workspace
      </button>
      <button class="ctx-item" onclick={wsIconClick}>
        <Smile size={13} weight="fill" /> Change icon…
      </button>
      <div class="ctx-sep"></div>
      <button class="ctx-item danger" onclick={wsDeleteClick}>
        <Trash2 size={13} weight="fill" /> Delete workspace
      </button>
    </ContextMenu>

    <ContextMenu bind:open={pkgMenuOpen} x={pkgMenuX} y={pkgMenuY}>
      <button
        class="ctx-item"
        onclick={() => {
          pkgMenuOpen = false;
          if (pkgMenuTarget) void onSelectPackage(pkgMenuTarget);
        }}
      >
        <FolderOpen size={13} weight="fill" /> Open folder view
      </button>
      <button class="ctx-item" onclick={pkgRenameClick} disabled>
        <Pencil size={13} weight="fill" /> Rename (soon)
      </button>
      <div class="ctx-sep"></div>
      <button class="ctx-item danger" onclick={pkgDeleteClick}>
        <Trash2 size={13} weight="fill" /> Remove from workspace
      </button>
    </ContextMenu>

    {#if modal === "ws-rename" && workspaces.active}
      <EditNameModal
        title="Rename workspace"
        initial={workspaces.active.name}
        busy={modalBusy}
        error={modalError}
        onsubmit={commitWsRename}
        oncancel={() => (modal = null)}
      />
    {:else if modal === "ws-icon" && workspaces.active}
      <EditIconModal
        title="Workspace icon"
        name={workspaces.active.name}
        initial={workspaces.active.icon}
        error={modalError}
        onchange={commitWsIcon}
        oncancel={() => (modal = null)}
      />
    {:else if modal === "pkg-rename" && pkgMenuTarget}
      <EditNameModal
        title="Rename package"
        initial={pkgMenuTarget}
        busy={modalBusy}
        error={modalError}
        onsubmit={commitPkgRename}
        oncancel={() => (modal = null)}
      />
    {/if}
  </div>
{/if}

<ToastStack />

<ContextMenu
  bind:open={createPackage.menuOpen}
  x={createPackage.menuX}
  y={createPackage.menuY}
>
  <button class="ctx-item" onclick={() => createPackage.chooseCreate()}>
    <PlusIcon size={13} weight="fill" /> Create new package
  </button>
  <button class="ctx-item" onclick={() => void createPackage.chooseImport()}>
    <FolderOpen size={13} weight="fill" /> Import folder…
  </button>
</ContextMenu>

{#if createPackage.modal}
  <CreatePackageModal
    data={createPackage.modal}
    onclose={() => createPackage.closeModal()}
  />
{/if}

<style>
  .loading {
    flex: 1 1 auto;
    background: var(--color-page);
  }
  .app {
    display: flex;
    flex: 1 1 auto;
    min-height: 0;
    min-width: 0;
    width: 100%;
    overflow: hidden;
  }
  /* Sidebar slides via width on this host (content stays 232px wide
   * inside so rows don't reflow mid-animation). */
  .sidebar-host {
    flex: 0 0 auto;
    width: 232px;
    display: flex;
    overflow: hidden;
    transition: width 0.22s cubic-bezier(0.2, 0, 0, 1);
  }
  .sidebar-host.closed {
    width: 0;
  }
  .sidebar-host :global(.sidebar) {
    transition:
      transform 0.22s cubic-bezier(0.2, 0, 0, 1),
      opacity 0.16s ease;
  }
  .sidebar-host.closed :global(.sidebar) {
    transform: translateX(-28px);
    opacity: 0;
  }
  @media (prefers-reduced-motion: reduce) {
    .sidebar-host,
    .sidebar-host :global(.sidebar) {
      transition: none;
    }
  }
  .main {
    flex: 1 1 auto;
    display: flex;
    flex-direction: column;
    min-width: 0;
    min-height: 0;
    overflow: hidden;
  }
  /* `.main` used to host the active panel directly; now it stacks
   * the panel on top + the optional TerminalDrawer below. Wrapping
   * the panel in `.main-content` keeps the existing flex layout
   * inside each panel intact. */
  .main-content {
    flex: 1 1 auto;
    display: flex;
    flex-direction: column;
    min-height: 0;
    overflow: hidden;
    /* Anchor for the absolutely-positioned DropOverlay. */
    position: relative;
  }
  /* Style danger context-menu items — ContextMenu uses :global(.ctx-item),
   * so this hook also has to be :global. */
  :global(.ctx-item.danger) {
    color: #ef4444;
  }
  :global(.ctx-item.danger:hover:not(:disabled)) {
    background: rgba(239, 68, 68, 0.10);
  }
</style>
