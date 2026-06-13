<script lang="ts">
  /**
   * Sidebar — Arc-browser-style collapsible left panel (replaces the old
   * 56px AppRail). Layout, top to bottom:
   *
   *   1. Workspace header — icon + name; click opens the WorkspaceSwitcher
   *      popover, right-click the workspace context menu.
   *   2. Main nav rows (Create).
   *   3. Hairline.
   *   4. Folders + apps — one row per package in the active workspace.
   *      • folder → solid folder icon; click expands inline to list the
   *        workbooks inside; click a workbook to open it as a tab.
   *      • app    → bare icon; click opens the app's workbook as a tab.
   *      Rows drag-reorder; order persists on the workspace.
   *   5. "+ New" row.
   *   6. Spacer, bottom nav rows (Network / Settings), account row.
   *
   * Tabs stay in the Titlebar (browser model) — the sidebar holds the
   * library, not the open windows.
   */
  import {
    Plus,
    SignIn,
    SignOut,
    ArrowsClockwise,
    User as UserIcon,
    CaretRight,
    CaretUpDown,
    Cube,
    BookmarkSimple,
  } from "phosphor-svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { slide } from "svelte/transition";
  import { invoke } from "@tauri-apps/api/core";
  import ContextMenu from "$lib/components/ContextMenu.svelte";
  import FolderIcon from "$lib/ui/FolderIcon.svelte";
  import Icon from "$lib/ui/Icon.svelte";
  import { tintFor, tintWash } from "$lib/ui/tint.svelte";
  import { fileIconUrl } from "$lib/ui/materialIcon";

  import { dnd } from "$lib/ui/dnd.svelte";
  import { docIcons } from "$lib/ui/docIcon.svelte";
  import { auth } from "$lib/auth/store.svelte";
  import { features } from "$lib/bridge/features";
  import { nav } from "$lib/bridge/nav.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { bookmarks } from "$lib/bridge/bookmarks.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { onboarding } from "$lib/onboarding/onboarding.svelte";
  import { DEMO_WORKSPACES, DEMO_FOLDER_CHILDREN } from "$lib/onboarding/demo";
  import { setSidebar, type SidebarApi } from "$lib/sidebar/context";
  import type { WorkbookEntry } from "$lib/bridge/package.svelte";

  export type RailTab = {
    id: string;
    label: string;
    /** A phosphor-svelte icon component (rendered weight="fill"). */
    icon: typeof Plus;
  };

  export type RailPackage = {
    id: string;
    name: string;
    isActive: boolean;
    /** Single emoji / glyph / data-URL image. Empty = initials fallback. */
    icon?: string;
    /** `app` (a workbook → bare icon) or `folder` (a container → solid
     *  folder glyph + inline expansion). Undefined = folder. */
    kind?: "app" | "folder";
  };

  let {
    tabs = [],
    bottomTabs = [],
    onCreate,
    createActive = false,
    active = $bindable(),
    packages = [],
    workspaceName = "",
    workspaceIcon = "",
    onSwitchWorkspace,
    onSelectPackage,
    onOpenApp,
    onOpenWorkbook,
    onOpenWorkbookSplit,
    onMoveIntoFolder,
    loadWorkbooks,
    onReorderPackages,
    onCreatePackageMenu,
    onWorkspaceContext,
    onPackageContext,
  }: {
    tabs?: RailTab[];
    bottomTabs?: RailTab[];
    /** The branded Create CTA pinned above the bottom nav. */
    onCreate?: () => void;
    createActive?: boolean;
    active: string;
    packages?: RailPackage[];
    workspaceName?: string;
    workspaceIcon?: string;
    onSwitchWorkspace?: (anchor: HTMLElement) => void;
    /** Folder "open grid view" (context menu) — the legacy drawer. */
    onSelectPackage?: (id: string) => void;
    /** App click → open the app's workbook as a tab. */
    onOpenApp?: (id: string) => void;
    /** Workbook row (inside an expanded folder) → open as a tab. */
    onOpenWorkbook?: (path: string) => void;
    /** Open as a right-hand split pane (context menus). */
    onOpenWorkbookSplit?: (path: string) => void;
    /** Move a dragged app/workbook into a folder package. Resolve true
     *  on success so the folder listing refreshes. */
    onMoveIntoFolder?: (
      payload:
        | { type: "app"; id: string; name: string }
        | { type: "workbook"; path: string; title: string },
      folderId: string,
    ) => Promise<boolean>;
    /** Lazy-load the workbooks inside a folder package. */
    loadWorkbooks?: (id: string) => Promise<WorkbookEntry[]>;
    onReorderPackages?: (orderedIds: string[]) => void;
    onCreatePackageMenu?: (rect: DOMRect) => void;
    onWorkspaceContext?: (x: number, y: number) => void;
    onPackageContext?: (id: string, x: number, y: number) => void;
  } = $props();

  // Workspace icon-rail (Hub layout). Demo set during onboarding so the rail
  // is populated before any real workspaces exist; live workspaces otherwise.
  const wsList = $derived(
    onboarding.active
      ? DEMO_WORKSPACES
      : workspaces.workspaces.map((w) => ({ id: w.id, name: w.name, icon: w.icon })),
  );
  const wsActiveId = $derived(
    onboarding.active ? DEMO_WORKSPACES[0].id : (workspaces.active?.id ?? null),
  );
  function pickWorkspace(id: string) {
    void workspaces.setActive(id);
  }

  function initials(name: string): string {
    const words = name.trim().split(/[\s\-_]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return (name || "?").slice(0, 2).toUpperCase();
  }

  /** Any explicit icon value becomes the folder's corner badge (the
   *  Icon resolver handles mi:/lobe:/emoji/data: and maps legacy
   *  lucide: names to material defs). Empty = plain folder. */
  function emojiIcon(icon: string | undefined): string | null {
    return icon || null;
  }

  // ── Folder expansion — lazy workbook listing ─────────────────────────
  let expanded = $state<Record<string, boolean>>({});
  let folderBooks = $state<Record<string, WorkbookEntry[] | "loading">>({});

  async function loadFolder(id: string) {
    // During the tour, twirling a folder shows demo files (real paths → real
    // Material icons) so Shelf vs Map and the icon set are both demonstrable.
    if (onboarding.active) {
      folderBooks = { ...folderBooks, [id]: DEMO_FOLDER_CHILDREN[id] ?? [] };
      return;
    }
    if (!loadWorkbooks) return;
    folderBooks = { ...folderBooks, [id]: "loading" };
    try {
      const books = await loadWorkbooks(id);
      folderBooks = { ...folderBooks, [id]: books };
    } catch {
      folderBooks = { ...folderBooks, [id]: [] };
    }
  }

  async function toggleFolder(p: RailPackage) {
    const open = !expanded[p.id];
    expanded = { ...expanded, [p.id]: open };
    if (open && folderBooks[p.id] === undefined) await loadFolder(p.id);
  }

  // ── move-into-folder drop (wb-5fl.13): drag an app or workbook onto
  // a folder row to move it inside. Apps dragged between rows still
  // reorder; hovering a FOLDER while carrying an app/workbook means
  // "put it in here". ──────────────────────────────────────────────
  let folderHotId = $state<string | null>(null);

  function folderOver(e: DragEvent, pkg: RailPackage) {
    const p = dnd.payload;
    const movable =
      p && (p.type === "workbook" || (p.type === "app" && p.id !== pkg.id));
    if (movable) {
      e.preventDefault();
      e.stopPropagation();
      folderHotId = pkg.id;
      return;
    }
    onDragOver(e, pkg.id);
  }

  async function folderDrop(e: DragEvent, pkg: RailPackage) {
    const p = dnd.payload;
    folderHotId = null;
    e.preventDefault();
    if (!p || (p.type !== "workbook" && p.type !== "app")) return;
    e.stopPropagation();
    dnd.end();
    const ok = await onMoveIntoFolder?.(p, pkg.id);
    if (ok) {
      // Refresh the folder's listing (and the source folder's, cheaply:
      // drop all caches — they reload lazily on expand).
      folderBooks = {};
      if (expanded[pkg.id]) await loadFolder(pkg.id);
    }
  }

  // ── Drag-reorder of the dynamic items (apps + folders) ──────────────
  let order = $state<string[]>([]);
  let dragId = $state<string | null>(null);
  let overId = $state<string | null>(null);
  $effect(() => {
    if (!dragId) order = packages.map((p) => p.id);
  });
  const orderedPackages = $derived(
    order
      .map((id) => packages.find((p) => p.id === id))
      .filter(Boolean) as RailPackage[],
  );
  function onDragStart(id: string) {
    dragId = id;
  }
  function onDragOver(e: DragEvent, targetId: string) {
    e.preventDefault();
    overId = targetId;
    if (!dragId || dragId === targetId) return;
    const from = order.indexOf(dragId);
    const to = order.indexOf(targetId);
    if (from < 0 || to < 0) return;
    const next = [...order];
    next.splice(to, 0, next.splice(from, 1)[0]);
    order = next;
  }
  function onDragEnd() {
    if (dragId) onReorderPackages?.([...order]);
    dragId = null;
    overId = null;
  }

  // ── Bookmarks — the tile grid (drag a workbook in to bookmark it) ───
  // Backed by the bookmarks store (same one behind ⌘1..⌘9). The store
  // has no order field (Rust contract), so grid order is presentation
  // state: an id list persisted locally. Max 12 (3 rows of 4); drops
  // between tiles insert at that position.
  const MAX_BOOKMARKS = 12;
  const BM_ORDER_KEY = "sidebar.bookmarkOrder";
  let bmOrder = $state<string[]>(
    (() => {
      try {
        return JSON.parse(localStorage.getItem(BM_ORDER_KEY) ?? "[]");
      } catch {
        return [];
      }
    })(),
  );
  function saveBmOrder() {
    try {
      localStorage.setItem(BM_ORDER_KEY, JSON.stringify(bmOrder));
    } catch {
      /* non-fatal */
    }
  }
  const orderedBookmarks = $derived.by(() => {
    const byId = new Map(bookmarks.bookmarks.map((b) => [b.id, b]));
    const ordered = bmOrder
      .map((id) => byId.get(id))
      .filter(Boolean) as typeof bookmarks.bookmarks;
    const rest = bookmarks.bookmarks.filter((b) => !bmOrder.includes(b.id));
    return [...ordered, ...rest];
  });

  /** Anything that resolves to a real file can be bookmarked: workbooks
   *  (path) and apps (their workbook path). The grid never creates
   *  anything — it only holds references to docs that live in real
   *  folders. */
  const bookmarkDraggable = $derived(
    dnd.payload?.type === "workbook" || dnd.payload?.type === "app",
  );
  /** Insertion index while a workbook drag hovers the grid (visual gap). */
  let bmInsertIdx = $state<number | null>(null);

  function bmTileOver(e: DragEvent, idx: number) {
    if (!bookmarkDraggable) return;
    e.preventDefault();
    e.stopPropagation();
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    bmInsertIdx = e.clientX - r.left < r.width / 2 ? idx : idx + 1;
  }

  async function bookmarkDrop(e: DragEvent) {
    const p = dnd.payload;
    const idx = bmInsertIdx ?? orderedBookmarks.length;
    bmInsertIdx = null;
    if (p?.type !== "workbook" && p?.type !== "app") return;
    e.preventDefault();
    const path = await dnd.resolvePath();
    const title = p.type === "app" ? p.name : p.title;
    dnd.end();
    if (!path) return;
    const existing = bookmarks.bookmarks.find((b) => b.path === path);
    if (existing) {
      // Reorder: move the existing bookmark to the insertion point.
      const ids = orderedBookmarks.map((b) => b.id).filter((id) => id !== existing.id);
      const from = orderedBookmarks.findIndex((b) => b.id === existing.id);
      ids.splice(from >= 0 && from < idx ? idx - 1 : idx, 0, existing.id);
      bmOrder = ids;
      saveBmOrder();
      return;
    }
    if (bookmarks.bookmarks.length >= MAX_BOOKMARKS) {
      console.warn("[sidebar] bookmark grid full (max %d)", MAX_BOOKMARKS);
      return;
    }
    try {
      const b = await bookmarks.create(title, path);
      const ids = orderedBookmarks.map((x) => x.id).filter((id) => id !== b.id);
      ids.splice(Math.min(idx, ids.length), 0, b.id);
      bmOrder = ids;
      saveBmOrder();
    } catch (err) {
      console.warn("[sidebar] bookmark failed", err);
    }
  }

  async function removeBookmark(id: string) {
    try {
      await bookmarks.delete(id);
      bmOrder = bmOrder.filter((x) => x !== id);
      saveBmOrder();
    } catch (err) {
      console.warn("[sidebar] remove bookmark failed", err);
    }
  }

  // ── bookmark tile + workbook row context menus (wb-5fl.8) ──────────
  let bmMenuOpen = $state(false);
  let bmMenuX = $state(0);
  let bmMenuY = $state(0);
  let bmMenuTarget = $state<{ id: string; path: string; title: string } | null>(null);
  function onBookmarkContext(b: { id: string; path: string; title: string }, e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    bmMenuTarget = b;
    bmMenuX = e.clientX;
    bmMenuY = e.clientY;
    bmMenuOpen = true;
  }

  let wbMenuOpen = $state(false);
  let wbMenuX = $state(0);
  let wbMenuY = $state(0);
  let wbMenuTarget = $state<WorkbookEntry | null>(null);
  function onWorkbookContext(book: WorkbookEntry, e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    wbMenuTarget = book;
    wbMenuX = e.clientX;
    wbMenuY = e.clientY;
    wbMenuOpen = true;
  }
  async function wbBookmark() {
    const b = wbMenuTarget;
    wbMenuOpen = false;
    if (!b || bookmarks.bookmarks.some((x) => x.path === b.path)) return;
    try {
      await bookmarks.create(b.title, b.path);
    } catch (err) {
      console.warn("[sidebar] bookmark failed", err);
    }
  }

  let switchBtnEl: HTMLButtonElement | undefined = $state();

  // ── Account row (anonymous → signed-in avatar) ──────────────────────
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

  const accountLabel = $derived.by(() => {
    if (auth.status === "signed-in")
      return auth.user?.displayName ?? auth.user?.email ?? "Account";
    if (auth.status === "sidecar-offline") return "Engine offline";
    if (auth.status === "checking") return "Checking…";
    return "Sign in";
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

  function folderLeave(p: RailPackage) {
    if (folderHotId === p.id) folderHotId = null;
  }

  // Sidebar SDK (wb-aakl.16) — expose this host's state + actions through the
  // shared contract. Getters keep reactivity flowing to section/layout
  // components. This is the seam the built-in layouts (and, later, toolkit
  // sidebars) consume; sections move onto it incrementally.
  const api: SidebarApi = {
    get layout() { return nav.layout; },
    get packages() { return orderedPackages; },
    isExpanded: (id) => !!expanded[id],
    childrenOf: (id) => folderBooks[id],
    toggleFolder,
    get dragId() { return dragId; },
    get overId() { return overId; },
    get folderHotId() { return folderHotId; },
    startDrag: onDragStart,
    dragOver: onDragOver,
    dragEnd: onDragEnd,
    folderOver,
    folderLeave,
    folderDrop,
    openApp: (id) => onOpenApp?.(id),
    openWorkbook: (path) => onOpenWorkbook?.(path),
    packageContext: (id, x, y) => onPackageContext?.(id, x, y),
    workbookContext: onWorkbookContext,
    dndStart: (payload, e) => dnd.start(payload, e),
    dndEnd: () => dnd.end(),
  };
  setSidebar(api);
</script>

<svelte:window onclick={onWindowClick} onkeydown={handleMenuKey} />

<nav
  class="sidebar layout-{nav.layout}"
  aria-label="Primary"
  oncontextmenu={(e) => {
    // Empty-space right-click → the New menu (create / import). Any
    // interactive child handles its own context menu and stops here.
    const t = e.target as HTMLElement;
    if (t.closest("button")) return;
    e.preventDefault();
    onCreatePackageMenu?.(new DOMRect(e.clientX, e.clientY, 0, 0));
  }}
>
  <!-- Hub layout — a far-left workspace icon-rail. One icon per workspace;
       click switches. Only rendered in Hub; Shelf/Map are single-column. -->
  {#if nav.layout === "hub"}
    <div class="ws-rail" aria-label="Workspaces">
      {#each wsList as w (w.id)}
        <button
          type="button"
          class="ws-rail-btn"
          class:active={w.id === wsActiveId}
          title={w.name}
          aria-label={w.name}
          aria-pressed={w.id === wsActiveId}
          onclick={() => pickWorkspace(w.id)}
        >
          {#if w.icon}<span class="ws-rail-glyph">{w.icon}</span>
          {:else}<span class="ws-rail-initials">{initials(w.name)}</span>{/if}
        </button>
      {/each}
    </div>
  {/if}

  <div class="sb-body">
  <!-- Workspace header. In Hub the icon-rail IS the switcher, so the header
       is a plain (non-dropdown) label for the active workspace; Shelf/Map use
       the clickable switcher dropdown. -->
  {#if nav.layout === "hub"}
    <div class="ws-label-hub">{workspaceName || "Workspace"}</div>
  {:else}
  <button
    type="button"
    class="ws-header"
    aria-label="Switch workspace ({workspaceName || 'none'})"
    bind:this={switchBtnEl}
    onclick={() => switchBtnEl && onSwitchWorkspace?.(switchBtnEl)}
    oncontextmenu={(e) => {
      e.preventDefault();
      onWorkspaceContext?.(e.clientX, e.clientY);
    }}
  >
    <span class="ws-tile" class:has-image={workspaceIcon.startsWith("data:image/")}>
      {#if workspaceIcon.startsWith("data:image/")}
        <img class="ws-img" src={workspaceIcon} alt="" />
      {:else if workspaceIcon}
        <span class="ws-glyph">{workspaceIcon}</span>
      {:else}
        <span class="ws-initials">{initials(workspaceName)}</span>
      {/if}
    </span>
    <span class="ws-name">{workspaceName || "Workspace"}</span>
    <CaretUpDown size={13} weight="bold" class="ws-caret" aria-hidden="true" />
  </button>
  {/if}

  <!-- Bookmarks — Arc-style tile grid. Holds ONLY what was explicitly
       dragged in (apps or workbooks — every tile is a reference to a
       real file in a real folder; nothing is created here). Drop
       between tiles to insert. Max 3 rows of 4. Empty state is a
       persistent dashed slot with a bookmark glyph — always there to
       drag onto, no words.
       Shelf + Hub are bookmark-forward (grid shows); Map is tree-forward
       (grid hidden — the nested library is the focus). -->
  {#if nav.layout !== "map"}
  {#if orderedBookmarks.length === 0}
    <div
      class="bm-empty"
      class:pin-target={bookmarkDraggable}
      role="group"
      aria-label="Bookmarks"
      ondragover={(e) => {
        if (bookmarkDraggable) e.preventDefault();
      }}
      ondrop={bookmarkDrop}
    >
      <BookmarkSimple size={15} weight="fill" aria-hidden="true" />
    </div>
  {:else}
    <div
      class="tile-grid"
      class:pin-target={bookmarkDraggable}
      role="group"
      aria-label="Bookmarks"
      ondragover={(e) => {
        if (bookmarkDraggable) {
          e.preventDefault();
          if (bmInsertIdx === null) bmInsertIdx = orderedBookmarks.length;
        }
      }}
      ondragleave={(e) => {
        if (e.target === e.currentTarget) bmInsertIdx = null;
      }}
      ondrop={bookmarkDrop}
    >
      {#each orderedBookmarks as b, i (b.id)}
        {@const tint = tintFor(b.title)}
        {@const identity = docIcons.iconFor(b.path)}
        <button
          type="button"
          class="tile"
          class:insert-before={bmInsertIdx === i}
          class:insert-after={bmInsertIdx === i + 1 &&
            i === orderedBookmarks.length - 1}
          style="--tint:{tint}; --tint-wash:{tintWash(tint)};"
          title={b.title}
          aria-label={b.title}
          draggable="true"
          ondragstart={(e) =>
            dnd.start({ type: "workbook", path: b.path, title: b.title }, e)}
          ondragend={() => {
            dnd.end();
            bmInsertIdx = null;
          }}
          ondragover={(e) => bmTileOver(e, i)}
          ondrop={bookmarkDrop}
          onclick={() => onOpenWorkbook?.(b.path)}
          oncontextmenu={(e) => onBookmarkContext(b, e)}
        >
          {#if identity}
            <Icon value={identity} name={b.title} size={17} />
          {:else}
            <img class="mi" src={fileIconUrl(b.path)} alt="" />
          {/if}
        </button>
      {/each}
      {#if bookmarkDraggable && bookmarks.bookmarks.length < MAX_BOOKMARKS}
        <span class="pin-slot" aria-hidden="true"></span>
      {/if}
    </div>
  {/if}
  {/if}

  <!-- Main nav rows -->
  {#each tabs as tab (tab.id)}
    {@const TabIcon = tab.icon}
    <button
      type="button"
      class="row"
      class:active={active === tab.id}
      aria-pressed={active === tab.id}
      onclick={() => (active = tab.id)}
    >
      <span class="row-icon"><TabIcon size={16} weight="fill" aria-hidden="true" /></span>
      <span class="row-label">{tab.label}</span>
    </button>
  {/each}

  {#if packages.length > 0 || onCreatePackageMenu}
    <div class="hairline" aria-hidden="true"></div>
  {/if}

  <!-- Library — folders (expandable) + apps as rows. Apps drag into
       the bookmark grid above to pin them. -->
  <div class="library">
    {#each orderedPackages as pkg (pkg.id)}
      {#if (pkg.kind ?? "folder") === "app"}
        <button
          type="button"
          class="row app-row"
          class:dragging={dragId === pkg.id}
          class:drop-target={overId === pkg.id && dragId !== pkg.id}
          draggable="true"
          ondragstart={(e) => {
            onDragStart(pkg.id);
            dnd.start({ type: "app", id: pkg.id, name: pkg.name }, e);
          }}
          ondragover={(e) => onDragOver(e, pkg.id)}
          ondragend={() => {
            onDragEnd();
            dnd.end();
          }}
          ondrop={(e) => e.preventDefault()}
          onclick={() => onOpenApp?.(pkg.id)}
          oncontextmenu={(e) => {
            e.preventDefault();
            onPackageContext?.(pkg.id, e.clientX, e.clientY);
          }}
        >
          <span class="row-icon app" style="color: {tintFor(pkg.name)};">
            <Icon value={pkg.icon ?? ""} name={pkg.name} size={16} />
          </span>
          <span class="row-label">{pkg.name}</span>
        </button>
      {:else}
      <button
          type="button"
          class="row folder-row"
          class:active={pkg.isActive}
          class:dragging={dragId === pkg.id}
          class:drop-target={overId === pkg.id && dragId !== pkg.id}
          class:folder-hot={folderHotId === pkg.id}
          draggable="true"
          ondragstart={() => onDragStart(pkg.id)}
          ondragover={(e) => folderOver(e, pkg)}
          ondragleave={() => {
            if (folderHotId === pkg.id) folderHotId = null;
          }}
          ondragend={onDragEnd}
          ondrop={(e) => folderDrop(e, pkg)}
          onclick={() => toggleFolder(pkg)}
          oncontextmenu={(e) => {
            e.preventDefault();
            onPackageContext?.(pkg.id, e.clientX, e.clientY);
          }}
          aria-expanded={!!expanded[pkg.id]}
        >
          <span class="caret" class:open={expanded[pkg.id]}>
            <CaretRight size={11} weight="bold" aria-hidden="true" />
          </span>
          <span class="row-icon">
            <!-- A folder is ALWAYS a folder: base shape + color, with the
                 chosen icon as a corner badge (composable, not swapped). -->
            <FolderIcon
              size={20}
              color={tintFor(pkg.name)}
              badge={emojiIcon(pkg.icon) ?? ""}
              name={pkg.name}
            />
          </span>
          <span class="row-label">{pkg.name}</span>
        </button>

        {#if expanded[pkg.id]}
          {@const books = folderBooks[pkg.id]}
          <div class="folder-children" transition:slide={{ duration: 140, easing: cubicOut }}>
            {#if books === "loading"}
              <span class="child-note">Loading…</span>
            {:else if !books || books.length === 0}
              <span class="child-note">No workbooks</span>
            {:else}
              {#each books as book (book.path)}
                {@const identity = docIcons.iconFor(book.path)}
                <button
                  type="button"
                  class="row child"
                  draggable="true"
                  ondragstart={(e) =>
                    dnd.start(
                      { type: "workbook", path: book.path, title: book.title },
                      e,
                    )}
                  ondragend={() => dnd.end()}
                  onclick={() => onOpenWorkbook?.(book.path)}
                  oncontextmenu={(e) => onWorkbookContext(book, e)}
                  title={book.path}
                >
                  <span class="row-icon book">
                    {#if identity}
                      <Icon value={identity} name={book.title} size={14} />
                    {:else}
                      <img class="mi sm" src={fileIconUrl(book.path)} alt="" />
                    {/if}
                  </span>
                  <span class="row-label">{book.title}</span>
                </button>
              {/each}
            {/if}
          </div>
        {/if}
      {/if}
    {/each}
  </div>

  <span class="bottom-spacer" aria-hidden="true"></span>

  {#if onCreate}
    <button
      type="button"
      class="create-cta"
      class:engaged={createActive}
      onclick={onCreate}
    >
      <Plus size={15} weight="bold" aria-hidden="true" />
      Create
    </button>
  {/if}

  <!-- Bottom toolbar — account avatar (auth-UI-gated, wb-aakl.16/.3) +
       icon-only utility nav. The shipped browser shows just the utility
       nav; the account row returns with WB_FF_AUTH_UI. -->
  <div class="bottom-bar">
    {#if features.authUI}
      <button
        type="button"
        class="avatar-btn"
        bind:this={accountBtnEl}
        title={accountLabel}
        aria-label={accountLabel}
        aria-haspopup="menu"
        aria-expanded={accountMenuOpen}
        onclick={handleAccountClick}
        disabled={auth.status === "checking" || accountBusy}
      >
        {#if auth.status === "signed-in"}
          {#if auth.user?.picture}
            <img class="account-avatar lg2 account-avatar-img" src={auth.user.picture} alt="" referrerpolicy="no-referrer" />
          {:else}
            <span class="account-avatar lg2">{accountInitial()}</span>
          {/if}
        {:else if auth.status === "sidecar-offline"}
          <span class="account-anon lg2 offline">
            <ArrowsClockwise size={14} weight="fill" class={accountBusy ? "spinning" : ""} />
          </span>
        {:else}
          <span class="account-anon lg2"><UserIcon size={15} weight="fill" /></span>
        {/if}
      </button>
    {/if}
    {#each bottomTabs as tab (tab.id)}
      {@const TabIcon = tab.icon}
      <button
        type="button"
        class="bar-btn"
        class:active={active === tab.id}
        title={tab.label}
        aria-label={tab.label}
        aria-pressed={active === tab.id}
        onclick={() => (active = tab.id)}
      >
        <TabIcon size={17} weight="fill" aria-hidden="true" />
      </button>
    {/each}
  </div>

  {#if accountMenuOpen && features.authUI}
    <div
      class="account-menu"
      role="menu"
      data-account-menu
      transition:fly={{ y: 4, duration: 140, easing: cubicOut }}
    >
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
          <span class="account-avatar lg muted"><UserIcon size={16} weight="fill" /></span>
          <div class="account-menu-meta">
            <span class="account-name muted">Not signed in</span>
            <span class="account-email">Workbooks works without an account — sign in to use the network.</span>
          </div>
        {/if}
      </div>

      <div class="account-menu-divider"></div>

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

      {#if auth.status === "signed-in"}
        <button
          type="button"
          class="account-menu-item"
          role="menuitem"
          onclick={handleSignOut}
          disabled={accountBusy}
        >
          <SignOut size={13} weight="fill" />
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
          <SignIn size={13} weight="fill" />
          {accountBusy ? "Opening sign-in…" : "Sign in to Workbooks"}
        </button>
        <button
          type="button"
          class="account-menu-item subtle"
          role="menuitem"
          onclick={resetLocalSession}
          disabled={resetting}
        >
          <ArrowsClockwise size={13} weight="fill" class={resetting ? "spinning" : ""} />
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
          <ArrowsClockwise size={13} weight="fill" class={accountBusy ? "spinning" : ""} />
          Restart engine
        </button>
      {/if}
    </div>
  {/if}
  </div>
</nav>

<ContextMenu bind:open={bmMenuOpen} x={bmMenuX} y={bmMenuY}>
  <button
    class="ctx-item"
    onclick={() => {
      bmMenuOpen = false;
      if (bmMenuTarget) onOpenWorkbook?.(bmMenuTarget.path);
    }}
  >
    Open
  </button>
  <button
    class="ctx-item"
    onclick={() => {
      bmMenuOpen = false;
      if (bmMenuTarget) onOpenWorkbookSplit?.(bmMenuTarget.path);
    }}
  >
    Open in split
  </button>
  <div class="ctx-sep"></div>
  <button
    class="ctx-item"
    onclick={() => {
      bmMenuOpen = false;
      if (bmMenuTarget) void removeBookmark(bmMenuTarget.id);
    }}
  >
    Remove bookmark
  </button>
</ContextMenu>

<ContextMenu bind:open={wbMenuOpen} x={wbMenuX} y={wbMenuY}>
  <button
    class="ctx-item"
    onclick={() => {
      wbMenuOpen = false;
      if (wbMenuTarget) onOpenWorkbook?.(wbMenuTarget.path);
    }}
  >
    Open
  </button>
  <button
    class="ctx-item"
    onclick={() => {
      wbMenuOpen = false;
      if (wbMenuTarget) onOpenWorkbookSplit?.(wbMenuTarget.path);
    }}
  >
    Open in split
  </button>
  <div class="ctx-sep"></div>
  <button
    class="ctx-item"
    onclick={wbBookmark}
    disabled={!!wbMenuTarget &&
      bookmarks.bookmarks.some((b) => b.path === wbMenuTarget?.path)}
  >
    Bookmark
  </button>
  <button
    class="ctx-item"
    onclick={() => {
      wbMenuOpen = false;
      if (wbMenuTarget) void navigator.clipboard.writeText(wbMenuTarget.path);
    }}
  >
    Copy path
  </button>
</ContextMenu>

<style>
  .sidebar {
    flex-shrink: 0;
    width: 232px;
    height: 100%;
    min-height: 100%;
    display: flex;
    flex-direction: row;
    /* The shared chrome surface (same as the titlebar) so the shell
     * reads as one frame; the canvas floats inside it. */
    background: var(--color-chrome);
    position: relative;
    z-index: 100;
    overflow: hidden;
  }
  /* The scrolling single column that holds the header, bookmarks + library.
   * In Hub it sits right of the workspace rail; in Shelf/Map it's the whole
   * sidebar. */
  .sb-body {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 0.6rem 0.5rem 0.75rem;
    overflow-y: auto;
    overflow-x: hidden;
  }

  /* ── Hub — workspace icon-rail ───────────────────────────────────── */
  .layout-hub { width: 288px; }
  .ws-rail {
    flex: 0 0 52px;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    padding: 0.6rem 0 0.75rem;
    overflow-y: auto;
    overflow-x: hidden;
    border-right: 1px solid var(--color-border);
  }
  .ws-rail-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    width: 36px;
    height: 36px;
    border-radius: 11px;
    border: 1px solid transparent;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font-size: 16px;
    line-height: 1;
    cursor: pointer;
    transition: transform 0.14s, border-color 0.14s, box-shadow 0.14s;
  }
  .ws-rail-btn:hover {
    transform: translateY(-1px);
    border-color: var(--color-border-strong);
  }
  .ws-rail-btn.active {
    border-color: var(--color-brand);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-brand) 30%, transparent);
  }
  .ws-rail-initials {
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 600;
    letter-spacing: 0.02em;
  }

  /* ── pinned app tiles ─────────────────────────────────────────── */
  .tile-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 6px;
    padding: 2px 2px 6px;
  }
  /* Bookmark tiles: the native icon as-is on a faint neutral surface (no
   * pastel matte, no recolor — same icon treatment as the nav rows). */
  .tile {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    height: 40px;
    border-radius: 10px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    font-size: 16px;
    line-height: 1;
    cursor: pointer;
    box-shadow: 0 1px 1.5px rgba(18, 19, 22, 0.05);
    transition: transform 0.14s cubic-bezier(0.2, 0, 0, 1), border-color 0.14s;
  }
  .tile:hover {
    transform: translateY(-1px);
    border-color: var(--color-border-strong);
  }
  .tile:active {
    transform: translateY(0) scale(0.97);
    box-shadow: 0 1px 1.5px rgba(15, 15, 15, 0.05);
  }
  .tile :global(img) {
    width: 22px;
    height: 22px;
    object-fit: cover;
    border-radius: 6px;
  }
  .tile.dragging { opacity: 0.4; }
  .tile.drop-target { box-shadow: inset 0 0 0 2px var(--tint); }
  /* Insertion marker while dragging a workbook between bookmark tiles. */
  .tile.insert-before,
  .tile.insert-after {
    position: relative;
  }
  .tile.insert-before::before,
  .tile.insert-after::after {
    content: "";
    position: absolute;
    top: 4px;
    bottom: 4px;
    width: 3px;
    border-radius: 2px;
    background: var(--color-brand);
    box-shadow: 0 0 6px color-mix(in srgb, var(--color-brand) 55%, transparent);
  }
  .tile.insert-before::before { left: -4.5px; }
  .tile.insert-after::after { right: -4.5px; }
  /* Empty bookmarks shelf — wordless dashed slot, always present so
     there's always something to drag onto. */
  .bm-empty {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 40px;
    margin: 2px 2px 6px;
    border-radius: 10px;
    border: 1.5px dashed var(--color-border-strong);
    color: var(--color-fg-subtle);
    transition: border-color 0.14s, color 0.14s, background 0.14s;
  }
  .bm-empty.pin-target {
    border-color: color-mix(in srgb, var(--color-brand) 55%, transparent);
    color: var(--color-brand);
    background: var(--color-brand-soft);
    animation: pin-pulse 1.1s ease-in-out infinite;
  }

  /* While a workbook drag is live, show the open slot it would land in. */
  .pin-slot {
    height: 40px;
    border-radius: 10px;
    border: 1.5px dashed color-mix(in srgb, var(--color-brand) 45%, transparent);
    background: var(--color-brand-soft);
    animation: pin-pulse 1.1s ease-in-out infinite;
  }
  @keyframes pin-pulse {
    0%, 100% { opacity: 0.55; }
    50% { opacity: 1; }
  }

  /* ── Create — THE primary CTA: live green, ink text, mono voice. ── */
  /* Soft, blended fill (not bright white) with a physical lip: a thicker
   * darker bottom edge + a top sheen + a contact shadow give it depth,
   * like a pressable key. Pressing collapses the lip. */
  .create-cta {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    width: 100%;
    height: 34px;
    margin-bottom: 0.2rem;
    border: 1px solid var(--color-border-strong);
    border-bottom-width: 3px;
    border-bottom-color: var(--color-fg-subtle);
    border-radius: 10px;
    background: color-mix(in srgb, var(--color-fg) 6%, var(--color-surface));
    color: var(--color-fg);
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 500;
    letter-spacing: -0.01em;
    cursor: pointer;
    flex-shrink: 0;
    /* top sheen (raised) + soft contact shadow below */
    box-shadow:
      inset 0 1px 0 color-mix(in srgb, var(--color-page) 65%, transparent),
      0 3px 8px -3px rgba(18, 19, 22, 0.2);
    transition:
      background 0.12s,
      border-color 0.12s,
      box-shadow 0.12s,
      border-bottom-width 0.06s,
      transform 0.06s;
  }
  .create-cta:hover,
  .create-cta.engaged {
    background: color-mix(in srgb, var(--color-fg) 10%, var(--color-surface));
    border-color: var(--color-fg-subtle);
  }
  /* press: lip collapses + the button sinks onto its shadow */
  .create-cta:active {
    border-bottom-width: 1px;
    transform: translateY(2px);
    box-shadow:
      inset 0 1px 0 color-mix(in srgb, var(--color-page) 65%, transparent),
      0 1px 3px -2px rgba(18, 19, 22, 0.2);
  }

  /* ── workspace header ─────────────────────────────────────────── */
  .ws-header {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 5px 6px;
    margin-bottom: 0.35rem;
    border: 0;
    border-radius: 8px;
    background: transparent;
    cursor: pointer;
    font: inherit;
    color: var(--color-fg);
    text-align: left;
    transition: background 0.15s;
  }
  .ws-header:hover { background: var(--color-surface-soft); }
  .ws-header :global(.ws-caret) {
    margin-left: auto;
    color: var(--color-fg-subtle);
    flex-shrink: 0;
  }
  .ws-tile {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border-radius: 7px;
    /* Theme-following chip — a dark tile in light mode read as a bug. */
    background: var(--color-surface);
    color: var(--color-fg);
    border: 1px solid var(--color-border);
    box-shadow: 0 1px 1.5px rgba(15, 15, 15, 0.05);
    flex-shrink: 0;
    overflow: hidden;
  }
  .ws-tile.has-image { background: transparent; border: 0; }
  .ws-initials { font-size: 10px; font-weight: 600; letter-spacing: 0.02em; }
  .ws-glyph { font-size: 14px; line-height: 1; }
  .ws-img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .ws-name {
    font-size: 13px;
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }

  /* ── rows ─────────────────────────────────────────────────────── */
  /* Brand idiom (lander nav ref): top-level rows carry a pastel
   * rounded-square icon chip + a mono uppercase tracked label.
   * Children (workbooks inside folders) stay quiet sans rows. */
  /* Composable nav presets (wb-aakl.16): "library" is the comfortable,
   * full-label default; "rail" is a compact, tighter density. Both keep
   * chips + labels — rail just trims the rhythm. (A future icon-only rail
   * is a further preset.) */
  /* Shelf — compact, bookmark-forward density. */
  /* Shelf — compact, bookmark-forward density. */
  .layout-shelf .row { height: 30px; gap: 8px; }
  .layout-shelf .row-icon { width: 22px; height: 22px; border-radius: 6px; }
  .layout-shelf .row-label { font-size: 10px; letter-spacing: 0.07em; }
  .layout-shelf .ws-header { padding-top: 6px; padding-bottom: 6px; }

  /* Map — tree-forward: roomier rows, indent guide lines on nested children
   * so it reads as a real page tree (the bookmark grid is hidden in markup). */
  .layout-map .row { height: 34px; }
  .layout-map .folder-children {
    padding-left: 14px;
    margin-left: 12px;
    border-left: 1px solid var(--color-border);
  }
  .layout-map .row.child { height: 30px; }

  /* Hub — plain (non-dropdown) workspace label; the rail is the switcher. */
  .ws-label-hub {
    padding: 8px 8px 6px;
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
  }

  .row {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    height: 38px;
    padding: 0 8px;
    border: 0;
    border-radius: 9px;
    background: transparent;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 13px;
    text-align: left;
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.15s, color 0.15s;
  }
  .row:hover {
    background: color-mix(in srgb, var(--color-fg) 5%, transparent);
    color: var(--color-fg);
  }
  /* Selection = a raised card (Dia's white pill), not a darker wash. */
  .row.active {
    background: var(--color-surface);
    color: var(--color-fg);
    box-shadow:
      0 1px 2px rgba(18, 19, 22, 0.07),
      inset 0 0 0 1px var(--color-border);
  }
  /* Icons render AS-IS from the universal library — native Material Icon
   * Theme colors (Kanban green, Notes blue, the HTML5 mark…) and emoji in
   * their own colors. No pastel chip matte, no recolor. (Dropping the chip
   * also kills the matte-flicker on folder expand — there's no nth-child
   * color cycle to reshuffle anymore.) */
  .row-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    flex-shrink: 0;
  }
  .row-label {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
    flex: 1 1 auto;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.09em;
    text-transform: uppercase;
  }
  /* Material file/folder icons (img assets). */
  .mi {
    width: 17px;
    height: 17px;
    display: block;
  }
  .mi.sm {
    width: 15px;
    height: 15px;
  }

  .library {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-height: 0;
  }

  /* folder rows */
  .caret {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 12px;
    flex-shrink: 0;
    color: var(--color-fg-subtle);
    transition: transform 0.12s;
  }
  .caret.open { transform: rotate(90deg); }
  /* Folders are NEVER a pastel chip — just the colored folder glyph, no
   * matte. The .row.folder-row selector matches the nth-child chip rules'
   * specificity and wins on source order, so folders stay transparent
   * regardless of their position in the list. */
  .row.folder-row .row-icon {
    background: transparent;
  }
  .folder-row { color: var(--color-fg); cursor: grab; }
  .folder-row:active { cursor: grabbing; }
  /* Carrying an app/workbook over a folder = "drop inside" affordance. */
  .folder-row.folder-hot {
    background: var(--color-brand-soft);
    box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--color-brand) 50%, transparent);
    color: var(--color-fg);
  }
  .app-row { color: var(--color-fg); cursor: grab; }
  .app-row:active { cursor: grabbing; }
  .app-row .row-icon.app {
    font-size: 15px;
    line-height: 1;
    font-weight: 600;
    overflow: hidden;
  }
  .app-row .row-icon.app :global(img) {
    width: 18px;
    height: 18px;
    object-fit: cover;
    border-radius: 5px;
  }
  .row.dragging { opacity: 0.4; }
  .row.drop-target { box-shadow: inset 0 2px 0 var(--color-fg); }

  .folder-children {
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding-left: 18px;
  }
  .row.child {
    height: 28px;
    font-size: 12.5px;
    color: var(--color-fg-muted);
  }
  /* children drop the chip + mono idiom — quiet sans rows */
  .row.child .row-icon {
    width: 18px;
    height: 18px;
    background: transparent;
    color: var(--color-fg-subtle);
  }
  .row.child .row-label {
    font-family: var(--font-sans);
    font-size: 12.5px;
    font-weight: 400;
    letter-spacing: 0;
    text-transform: none;
  }
  .child-note {
    padding: 4px 8px 5px 26px;
    font-size: 11.5px;
    color: var(--color-fg-subtle);
  }

  .hairline {
    height: 1px;
    background: var(--color-border);
    margin: 0.4rem 6px;
    flex-shrink: 0;
  }
  .bottom-spacer {
    flex: 1 1 auto;
    min-height: 0.4rem;
  }

  /* ── bottom toolbar (avatar · settings · network) + account menu ── */
  .bottom-bar {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 2px 2px 0;
    flex-shrink: 0;
  }
  .avatar-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border: 0;
    border-radius: 10px;
    background: transparent;
    cursor: pointer;
    padding: 0;
    transition: background 0.15s;
  }
  .avatar-btn:hover { background: color-mix(in srgb, var(--color-fg) 5%, transparent); }
  .avatar-btn:disabled { opacity: 0.6; cursor: default; }
  .bar-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    border: 0;
    border-radius: 9px;
    background: transparent;
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }
  .bar-btn:hover {
    background: color-mix(in srgb, var(--color-fg) 5%, transparent);
    color: var(--color-fg);
  }
  .bar-btn.active {
    background: var(--color-surface);
    color: var(--color-fg);
    box-shadow:
      0 1px 2px rgba(15, 15, 15, 0.07),
      inset 0 0 0 1px var(--color-border);
  }
  .account-avatar.lg2,
  .account-anon.lg2 {
    width: 28px;
    height: 28px;
    font-size: 12px;
  }
  .account-anon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background: var(--color-surface-soft);
    border: 1px dashed var(--color-border);
    color: var(--color-fg-muted);
  }
  .account-anon.offline {
    border-style: solid;
    border-color: color-mix(in srgb, var(--color-warn) 45%, transparent);
    color: var(--color-warn);
  }
  .account-avatar {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 10px;
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
    background: var(--color-surface-soft);
    color: transparent;
  }
  :global(.spinning) {
    animation: spin 900ms linear infinite;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .account-menu {
    position: absolute;
    left: 8px;
    right: 8px;
    bottom: 44px;
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
  .status-dot.dot-ok      { background: var(--color-ok); }
  .status-dot.dot-pending { background: var(--color-warn); animation: pulse 1200ms ease-in-out infinite; }
  .status-dot.dot-warn    { background: var(--color-warn); }
  .status-dot.dot-err     { background: var(--color-err); } /* no error token in canon */
  .status-dot.dot-idle    { background: var(--color-fg-muted); opacity: 0.45; }
  .status-label {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-fg-muted);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    font-weight: 500;
  }
  .status-val {
    font-family: var(--font-mono);
    font-size: 12px;
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
  .account-menu-item.subtle {
    color: var(--color-fg-muted);
    font-size: 0.78rem;
  }
  .account-menu-item.subtle:hover:not(:disabled) {
    color: var(--color-fg);
  }
</style>
