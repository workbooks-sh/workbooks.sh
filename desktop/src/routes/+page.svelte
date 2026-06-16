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
  import HomePanel from "$lib/home/HomePanel.svelte";
  import PackageTreeDrawer from "$lib/components/PackageTreeDrawer.svelte";
  import { FolderOpen, Plus as PlusIcon } from "phosphor-svelte";
  import CreatePackageModal from "$lib/home/CreatePackageModal.svelte";
  import ShareOrgModal from "$lib/network/components/ShareOrgModal.svelte";
  import PaletteModal from "$lib/palette/PaletteModal.svelte";
  import { createPackage } from "$lib/home/createPackage.svelte";
  import TerminalDrawer from "$lib/components/TerminalDrawer.svelte";
  import DocViewer from "$lib/viewer/DocViewer.svelte";
  import DropOverlay from "$lib/viewer/DropOverlay.svelte";
  import ToastStack from "$lib/components/ToastStack.svelte";
  import WorkspaceOnboarding from "$lib/workspace/WorkspaceOnboarding.svelte";
  import OnboardingFlow from "$lib/onboarding/OnboardingFlow.svelte";
  import SignInGate from "$lib/auth/SignInGate.svelte";
  import { auth } from "$lib/auth/store.svelte";
  import { setupStatus } from "$lib/bridge/setup.svelte";
  import WorkspaceSwitcher from "$lib/workspace/WorkspaceSwitcher.svelte";
  import EditNameModal from "$lib/workspace/EditNameModal.svelte";
  import EditIconModal from "$lib/workspace/EditIconModal.svelte";
  import ContextMenu from "$lib/components/ContextMenu.svelte";
  import SearchDrawer from "$lib/components/SearchDrawer.svelte";
  import SearchExplainer from "$lib/components/SearchExplainer.svelte";
  import BookmarksPopover from "$lib/components/BookmarksPopover.svelte";
  import NexusPopover from "$lib/components/NexusPopover.svelte";
  import { bookmarks } from "$lib/bridge/bookmarks.svelte";
  import { panes } from "$lib/viewer/panes.svelte";
  import { themes } from "$lib/bridge/themes.svelte";
  import { PencilSimple as Pencil, Smiley as Smile, Trash as Trash2 } from "phosphor-svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { ws } from "$lib/bridge/ws.svelte";
  import { tabs } from "$lib/tabs/store.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { features } from "$lib/bridge/features";
  import { openIntent } from "$lib/bridge/openIntent";
  import { dock } from "$lib/bridge/dock.svelte";
  import DockHost from "$lib/components/DockHost.svelte";
  import WaldoMark from "$lib/components/WaldoMark.svelte";
  import { search } from "$lib/search/registry.svelte";
  import { BUILTIN_PROVIDERS } from "$lib/search/builtins";
  import { applyBootPrefs } from "$lib/onboarding/prefs";
  import { onboarding } from "$lib/onboarding/onboarding.svelte";
  import { DEMO_PACKAGES, DEMO_ACTIVE_WORKSPACE } from "$lib/onboarding/demo";
  import { nav } from "$lib/bridge/nav.svelte";
  import { commands } from "$lib/chrome/commands.svelte";
  import {
    MagnifyingGlass as SearchCmdIcon,
    BookmarkSimple as BookmarkCmdIcon,
    Terminal as TerminalCmdIcon,
  } from "phosphor-svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { docIcons } from "$lib/ui/docIcon.svelte";
  import { terminalDrawer } from "$lib/bridge/terminal.svelte";

  /* Sidebar sections. Create is the branded CTA above the bottom nav
   * (not a plain row); Network/Settings are bottom-pinned utility rows. */
  // Order = left→right in the sidebar's bottom toolbar (after avatar).
  // Network is flag-gated (wb-aakl.1) — the tab disappears entirely when
  // WB_FF_NETWORK is off (the shipped browser default).
  // Settings moved into the titlebar ⌄ menu (alongside Search/Bookmarks/
  // Terminal). The bottom rail is now Network-only, and only when flagged on.
  const bottomRailTabs: RailTab[] = [
    ...(features.network
      ? [{ id: "network", label: "Network", icon: NetworkIcon }]
      : []),
  ];

  // The agent panel is now a dock registrant (wb-aakl.14): when WB_FF_AGENTS
  // is on it registers an "agent" panel + toolbar icon, lazily loaded so a
  // flags-off build still excludes the chunk. NetworkPanel stays a main-area
  // section, lazily imported behind its flag.
  let NetworkPanel = $state<typeof import("$lib/network/NetworkPanel.svelte").default | null>(null);
  $effect(() => {
    if (features.network && !NetworkPanel)
      void import("$lib/network/NetworkPanel.svelte").then((m) => (NetworkPanel = m.default));
  });

  // Section registry (wb-aakl.16) — main-area panel per rail id. Replaces a
  // hardcoded if/else chain; network is flag-gated + lazy. A function (not a
  // static Map) so the reactive NetworkPanel import is picked up on resolve.
  function sectionFor(id: string) {
    switch (id) {
      case "home": return HomePanel;
      case "settings": return SettingsContainer;
      case "network": return features.network ? NetworkPanel : null;
      default: return null;
    }
  }
  const sectionLabels: Record<string, string> = {
    home: "Create",
    network: "Network",
    settings: "Settings",
  };

  let active = $state("home");
  let lastRail = $state("home");

  // CLI owns setup (wb-aakl.5): the browser is installed by `wb desktop
  // install` with the runtime already present, so there is no in-app
  // engine-install or keychain first-run wizard. The engine/keychain
  // setup gates are gone; engine state shows in the titlebar chip
  // (offline-first canon), never a blocking gate.
  //
  // Two gates remain, neither tied to "setup":
  //   needsWorkspace → WorkspaceOnboarding (core file-system UX: a fresh
  //     install with zero workspaces has nowhere to hang packages).
  //   firstRunDone   → OnboardingFlow (personalization choices, wb-aakl.20;
  //     `?onboarding` forces it for preview).
  let initialized = $state(true);
  let needsWorkspace = $state(false);
  let firstRunDone = $state(true);

  // Switcher popover state — anchor element + open flag.

  // Sidebar resize — drag the right edge; nav stores width per layout and the
  // canvas (.main, flex:1) reflows automatically. `resizing` kills the width
  // transition so the drag tracks the pointer 1:1.
  let resizing = $state(false);
  function startResize(e: PointerEvent) {
    e.preventDefault();
    resizing = true;
    const startX = e.clientX;
    const startW = nav.sidebarWidth;
    const onMove = (m: PointerEvent) => nav.setSidebarWidth(startW + (m.clientX - startX));
    const onUp = () => {
      resizing = false;
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

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
  type ModalKind = "ws-rename" | "ws-icon" | "pkg-icon" | null;
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
  function pkgIconClick() {
    pkgMenuOpen = false;
    modalError = null;
    modal = "pkg-icon";
  }
  async function commitPkgIcon(icon: string) {
    const id = pkgMenuTarget;
    if (!id) return;
    try {
      await packageStore.setIcon(id, icon);
    } catch (e) {
      modalError = e instanceof Error ? e.message : String(e);
    }
  }
  async function pkgBookmarkApp() {
    const id = pkgMenuTarget;
    pkgMenuOpen = false;
    if (!id) return;
    try {
      const path = await invoke<string>("package_app_workbook", { name: id });
      if (!bookmarks.bookmarks.some((b) => b.path === path)) {
        await bookmarks.create(id, path);
      }
    } catch (e) {
      console.warn("[pkg] bookmark app failed", e);
    }
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

  // Demo packages shown ONLY during onboarding, so the freshly-revealed
  // sidebar is populated (the tour runs before any runtime/workspaces exist).
  // The folder badge is the emoji or the material-icon ref per the glyph pick,
  // so the emoji-vs-icon step flips the badges live.
  const demoRailPackages = $derived<RailPackage[]>(
    DEMO_PACKAGES.map((p) => ({
      id: p.id,
      name: p.name,
      isActive: false,
      icon: nav.glyphs === "emoji" ? p.emoji : p.badge,
      kind: p.kind,
    })),
  );

  // Filter the package list by the active workspace.
  const railPackages = $derived<RailPackage[]>(
    (() => {
      if (onboarding.active) return demoRailPackages;
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

  const pkgMenuKind = $derived(
    railPackages.find((p) => p.id === pkgMenuTarget)?.kind ?? "folder",
  );

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

  // Drag an app/workbook onto a folder row → move it inside. Backed by
  // package_move_into (real backend pending — wb-5fl.12; the webHost
  // mock implements it for the preview). False return leaves the
  // sidebar untouched.
  async function onMoveIntoFolder(
    payload:
      | { type: "app"; id: string; name: string }
      | { type: "workbook"; path: string; title: string },
    folderId: string,
  ): Promise<boolean> {
    try {
      await invoke("package_move_into", {
        item: payload.type === "app" ? payload.id : payload.path,
        kind: payload.type,
        folder: folderId,
      });
      await packageStore.refresh();
      await workspaces.refresh();
      return true;
    } catch (e) {
      console.warn("[sidebar] move into folder failed (backend pending, wb-5fl.12)", e);
      return false;
    }
  }

  // Folder context-menu "New workbook…" — the same create-workbook
  // wizard the folder grid uses, scoped to the folder.
  let pkgPaletteOpen = $state(false);
  let pkgPaletteWizard = $state<{ id: string; title: string } | null>(null);
  async function pkgNewWorkbook() {
    const id = pkgMenuTarget;
    pkgMenuOpen = false;
    if (!id) return;
    try {
      await packageStore.setActive(id);
    } catch (e) {
      console.warn("[pkg] setActive failed", e);
      return;
    }
    pkgPaletteWizard = { id: "create-workbook", title: "Create a workbook" };
    pkgPaletteOpen = true;
  }

  // Context-menu "Open in split" — open and pair with the visible doc.
  async function onOpenWorkbookSplit(path: string) {
    try {
      const prev = tabs.activeId;
      await tabs.open(path);
      if (tabs.activeId) panes.splitWith(tabs.activeId, "right", prev);
      chrome.mode = "doc";
    } catch (e) {
      console.warn("[sidebar] open split failed", e);
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
    chrome.openWorkspace(anchor);
  }

  async function onOnboardingComplete() {
    await workspaces.refresh();
    needsWorkspace = workspaces.workspaces.length === 0;
  }

  // First-run workspace (wb-2s09.9): once the nexus (local sidecar) is ready,
  // auto-create a default "Personal" workspace — no name form. The connect
  // screen (WorkspaceOnboarding) only shows while the nexus is unavailable.
  let autoWsTried = $state(false);
  $effect(() => {
    if (
      initialized &&
      needsWorkspace &&
      !autoWsTried &&
      sidecar.status.state === "ready"
    ) {
      autoWsTried = true;
      void workspaces
        .create("Personal", "✨")
        .then(onOnboardingComplete)
        .catch((e) => {
          console.warn("[workspace] auto-create failed", e);
          autoWsTried = false; // allow the connect screen / retry
        });
    }
  });

  onMount(() => {
    // No in-app engine wizard auto-open — the CLI installs the runtime
    // before the browser is ever opened (wb-aakl.5).
    sidecar.init();
    ws.init();
    tabs.init();
    packageStore.init();
    workspaces.init().then(() => {
      initialized = true;
      // Core file-system UX: a fresh install with zero workspaces gets the
      // create-first-workspace flow. Not "setup" — kept per wb-aakl.5.
      needsWorkspace = workspaces.workspaces.length === 0;
    });
    bookmarks.init();
    themes.init();
    // Apply persisted personalization (theme mode — wb-aakl.20).
    applyBootPrefs();
    // `wb desktop open <path>` deep link — read the intent on boot + focus.
    openIntent.watch();
    // Composable search (wb-aakl.19): register the built-in providers
    // (files/workbooks, bookmarks, tabs, nexus web). Toolkits add more.
    for (const p of BUILTIN_PROVIDERS) search.register(p);
    // Chrome command registry (wb-aakl.17): the built-in overflow-menu +
    // global commands register through the same seam toolkits use (dogfood).
    commands.register({ id: "search", label: "Search…", group: "menu", icon: SearchCmdIcon, shortcut: "⌘K", order: 0, run: () => chrome.openSearch() });
    commands.register({ id: "bookmarks", label: "Bookmarks", group: "menu", icon: BookmarkCmdIcon, order: 1, run: () => (chrome.bookmarksOpen = true) });
    commands.register({ id: "terminal", label: "Terminal", group: "menu", icon: TerminalCmdIcon, shortcut: "⌃`", order: 2, run: () => terminalDrawer.show() });
    commands.register({ id: "settings", label: "Settings", group: "menu", icon: SettingsIcon, order: 3, run: () => { chrome.mode = "app"; active = "settings"; } });
    // Waldo (wb-aakl.21) — the ONE resident agent, a first-party dock panel
    // registered ALWAYS (not flag-gated; it replaces the multi-agent chrome
    // with a single voice). Lazy-loaded like any dock panel.
    dock.register({
      id: "waldo",
      title: "Waldo", // tab tooltip; the panel is headerless (own Chats/collapse row)
      icon: WaldoMark,
      iconOnly: true,
      headerless: true,
      load: () => import("$lib/components/WaldoPanel.svelte"),
    });
    // (The old multi-agent chat panel — AgentPanel/ChatPanel/ChatHeader/
    // ChatComposer — was retired; WaldoPanel is the one canonical chat surface.)
    // Personalization onboarding (wb-aakl.20). first_run_done is a durable
    // flag in setup.json; `?onboarding` forces the flow for preview.
    const forceOnboarding = new URLSearchParams(window.location.search).has(
      "onboarding",
    );
    // A completed run is recorded BOTH durably (setup.json) and in localStorage.
    // Honor either, so a slow/flaky durable write (common in unsigned dev builds)
    // doesn't re-run the whole tour on every hot reload.
    const lsDone = (() => {
      try {
        return !!JSON.parse(localStorage.getItem("wb.browser.prefs") || "{}").completedAt;
      } catch {
        return false;
      }
    })();
    if (forceOnboarding) firstRunDone = false;
    else if (lsDone) firstRunDone = true;
    setupStatus()
      .then((s) => {
        if (!forceOnboarding) firstRunDone = s.first_run_done || lsDone;
      })
      .catch((e) => {
        // Fail-open: skip the personalization flow if the probe fails.
        console.warn("[setup] status check failed:", e);
      });
  });

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
    } else if (e.key === "j" && features.agents) {
      e.preventDefault();
      dock.toggle("agent");
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

{#if !initialized || auth.status === "checking"}
  <!-- Initial app + auth probe in flight — don't flash the sign-in
       screen before we know whether a session already exists. -->
  <div class="loading"></div>
{:else if auth.status !== "signed-in"}
  <!-- Mandatory sign-in (wb-xiei.1): no workspace, no app until the
       user has a Workbooks session. Sign-in is free; it secures their
       data. A stored session counts even when the engine is offline
       (offline-first), so signed-in users skip this regardless. -->
  <SignInGate />
{:else if needsWorkspace}
  <!-- Core file-system UX (wb-aakl.5): create the first workspace so
       packages have somewhere to live. Not a setup gate. -->
  <WorkspaceOnboarding oncomplete={onOnboardingComplete} />
{:else}
  <!-- The REAL app shell. During onboarding (wb-aakl.20) its pieces reveal
       one at a time as a tutorial; `onboarding.shows()` is always true once
       onboarding is done. -->
  <div class="app" class:ob-active={onboarding.active}>
    <div
      class="sidebar-host"
      class:closed={!chrome.sidebarOpen}
      class:resizing
      class:ob-hide={!onboarding.shows("sidebar")}
      inert={!chrome.sidebarOpen}
      style={chrome.sidebarOpen ? `width:${nav.sidebarWidth}px` : ""}
    >
      <Sidebar
        bottomTabs={bottomRailTabs}
        bind:active
        packages={railPackages}
        workspaceName={onboarding.active ? DEMO_ACTIVE_WORKSPACE.name : (workspaces.active?.name ?? "")}
        workspaceIcon={onboarding.active ? (nav.glyphs === "emoji" ? DEMO_ACTIVE_WORKSPACE.icon : DEMO_ACTIVE_WORKSPACE.mi) : (workspaces.active?.icon ?? "")}
        onSwitchWorkspace={onSwitchWorkspace}
        onSelectPackage={onSelectPackage}
        onOpenApp={onOpenApp}
        onOpenWorkbook={onOpenWorkbook}
        onOpenWorkbookSplit={onOpenWorkbookSplit}
        onMoveIntoFolder={onMoveIntoFolder}
        loadWorkbooks={(id) => packageStore.workbooks(id)}
        onReorderPackages={onReorderPackages}
        onCreatePackageMenu={onCreatePackageMenu}
        onWorkspaceContext={onWorkspaceContext}
        onPackageContext={onPackageContext}
      />
    </div>

    {#if chrome.sidebarOpen}
      <!-- Sidebar resize handle — drag to set this layout's width; the canvas
           reflows. (wb-aakl.16) -->
      <button
        type="button"
        class="resize-handle"
        aria-label="Resize sidebar"
        onpointerdown={startResize}
      ></button>
    {/if}

    {#if chrome.leftPanel === "files"}
      <PackageTreeDrawer />
    {/if}

    <main class="main" inert={onboarding.active}>
      <div
        class="main-content"
        class:ob-hide={!onboarding.shows("canvas")}
        class:bare={chrome.mode === "app" && active === "home"}
      >
        <DropOverlay />
        {#if dock.fullscreen}
          <!-- A dock panel popped out into a full tab (wb: Waldo-as-tab):
               it owns the whole canvas. Rendered above the doc/section
               surfaces; "dock back" (in the panel) returns it to the
               right-side dock. -->
          {#await dock.fullscreen.load?.() then mod}
            {#if mod?.default}
              {@const Full = mod.default}
              <div class="full-panel">
                <Full {...dock.fullscreen.props ?? {}} fullscreen={true} />
              </div>
            {/if}
          {/await}
        {:else if chrome.mode === "doc"}
          <DocViewer />
        {:else}
          {@const Section = sectionFor(active)}
          {#if Section}<Section />{/if}
        {/if}
      </div>
      <TerminalDrawer />
    </main>

    <!-- Search drawer — opens from the RIGHT (the browser "everything"
         search). Sits right of the canvas, beside the dock. During the tour
         an explainer card sits to its left describing the active search type. -->
    {#if chrome.leftPanel === "search" && onboarding.active}
      <SearchExplainer />
    {/if}
    {#if chrome.leftPanel === "search"}
      <SearchDrawer onclose={() => chrome.closeLeft()} />
    {/if}

    <DockHost />

    <WorkspaceSwitcher
      anchor={chrome.workspaceAnchor}
      bind:open={chrome.workspaceOpen}
    />

    <BookmarksPopover
      anchor={chrome.bookmarksAnchor}
      bind:open={chrome.bookmarksOpen}
    />

    <NexusPopover
      anchor={chrome.nexusAnchor}
      bind:open={chrome.nexusOpen}
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
      {#if pkgMenuKind === "app"}
        <button
          class="ctx-item"
          onclick={() => {
            pkgMenuOpen = false;
            if (pkgMenuTarget) void onOpenApp(pkgMenuTarget);
          }}
        >
          <FolderOpen size={13} weight="fill" /> Open
        </button>
        <button class="ctx-item" onclick={pkgBookmarkApp}>
          <PlusIcon size={13} weight="bold" /> Bookmark
        </button>
      {:else}
        <button
          class="ctx-item"
          onclick={() => {
            pkgMenuOpen = false;
            if (pkgMenuTarget) void onSelectPackage(pkgMenuTarget);
          }}
        >
          <FolderOpen size={13} weight="fill" /> Open folder view
        </button>
        <button class="ctx-item" onclick={pkgNewWorkbook}>
          <PlusIcon size={13} weight="bold" /> New workbook…
        </button>
      {/if}
      <button class="ctx-item" onclick={pkgIconClick}>
        <Smile size={13} weight="fill" /> Change icon…
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
    {:else if modal === "pkg-icon" && pkgMenuTarget}
      <EditIconModal
        title="Package icon"
        name={pkgMenuTarget}
        initial={packageStore.meta[pkgMenuTarget]?.icon ?? ""}
        error={modalError}
        onchange={commitPkgIcon}
        oncancel={() => (modal = null)}
      />
    {/if}
  </div>

  <!-- Coach lives OUTSIDE the inert .app so it stays interactive while the
       real shell behind it is frozen during the build-up. -->
  {#if !firstRunDone}
    <OnboardingFlow oncomplete={() => (firstRunDone = true)} />
  {/if}
{/if}

<ToastStack />

<ContextMenu
  bind:open={createPackage.menuOpen}
  x={createPackage.menuX}
  y={createPackage.menuY}
>
  <button class="ctx-item" onclick={() => createPackage.chooseCreate()}>
    <PlusIcon size={13} weight="fill" /> New folder
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

{#if createPackage.shareRequest}
  <ShareOrgModal
    resourceId={createPackage.shareRequest.resourceId}
    resourceTitle={createPackage.shareRequest.title}
    onclose={() => createPackage.clearShare()}
  />
{/if}

<PaletteModal
  open={pkgPaletteOpen}
  workdir={packageStore.active?.folders?.[0] ?? null}
  wizardMode={pkgPaletteWizard}
  onclose={() => {
    pkgPaletteOpen = false;
    pkgPaletteWizard = null;
  }}
  onwizardfinish={() => void packageStore.refresh()}
/>

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
    transition: width 0.22s cubic-bezier(0.2, 0, 0, 1),
      opacity 0.4s ease, transform 0.45s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .sidebar-host.closed {
    width: 0;
  }
  /* While dragging the handle, track the pointer 1:1 (no width easing). */
  .sidebar-host.resizing {
    transition: opacity 0.4s ease, transform 0.45s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  /* Resize handle — a slim hit area straddling the sidebar/canvas seam. */
  .resize-handle {
    flex: 0 0 auto;
    width: 6px;
    margin: 0 -3px;
    padding: 0;
    border: 0;
    background: transparent;
    cursor: col-resize;
    z-index: 110;
    position: relative;
  }
  .resize-handle::after {
    content: "";
    position: absolute;
    inset: 0 2px;
    border-radius: 2px;
    background: transparent;
    transition: background 0.15s;
  }
  .resize-handle:hover::after,
  .sidebar-host.resizing + .resize-handle::after {
    background: var(--color-border-strong);
  }
  /* Onboarding build-up: reveal the real sidebar with a slide-in. */
  .sidebar-host.ob-hide {
    opacity: 0;
    transform: translateX(-16px);
    pointer-events: none;
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
    /* The floating canvas (inset style): rounded opening with a gap on
     * the bottom + right so content reads as a card set into the
     * chrome frame. */
    margin: 0 8px 8px 0;
    border-radius: 12px;
    border: 1px solid var(--color-border);
    /* Graph-paper backdrop — the canonical canvas surface (create page +
     * empty states show it; open docs paint over it). */
    background-color: var(--color-page);
    background-image: var(--grid-image);
    background-size: var(--grid-size) var(--grid-size);
    box-shadow:
      0 1px 2px rgba(15, 15, 15, 0.05),
      0 4px 16px rgba(15, 15, 15, 0.04);
    transition: opacity 0.5s ease, transform 0.5s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  /* The create/home surface has NO card chrome — it shows the graph-paper
   * shader backdrop through, with its composer floating on top. */
  .main-content.bare {
    background-color: transparent;
    background-image: none;
    border-color: transparent;
    box-shadow: none;
  }
  /* Onboarding build-up: reveal the real canvas (with demo content). */
  .main-content.ob-hide {
    opacity: 0;
    transform: translateY(10px);
    pointer-events: none;
  }
  /* A popped-out dock panel filling the canvas as its own tab. */
  .full-panel {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
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
