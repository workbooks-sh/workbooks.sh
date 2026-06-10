<script lang="ts">
  /**
   * FileTreePanel (wb-i38o.7) — right-rail file tree.
   *
   * Renders one collapsible <details> root per allowed folder in the
   * active workspace. File rows click → tab_open (D8 stub for now).
   * Right-click opens a small context menu (Open in OS / Copy path).
   *
   * Two-tier filter at the top:
   *
   *   1. View toggle (wb-i38o.14): source ↔ compiled.
   *      - source (default): show all files.
   *      - compiled: show ONLY .html workbook files. Hides extension
   *        chips, since they don't apply.
   *   2. Extension chips (wb-i38o.7): all / .org / .html.
   *      Hidden in compiled view.
   *
   * `view_mode` is persisted per-workspace via `package_set_view_mode`
   * → ~/.oql/desktop/workspaces/<name>.json. Switching the toggle just
   * re-filters the in-memory tree; no re-walk.
   *
   * Empty states distinguish four cases:
   *   1. No active workspace
   *   2. Active workspace has zero folders
   *   3. Folder configured but walks empty
   *   4. Compiled view with no .html files (wb-i38o.14)
   */
  import { onMount, onDestroy } from "svelte";
  import { ArrowSquareOut as ExternalLink, Copy, Package, Package as PackageOpen, Code as Code2, Database, MagnifyingGlass as Search, X } from "phosphor-svelte";
  import { fileIconUrl, folderIconUrl } from "$lib/ui/materialIcon";
  import { fileTree, type FsEntry } from "$lib/bridge/fs_tree.svelte";
  import {
    packageStore,
    type Package as PackageDef,
    type ViewMode,
  } from "$lib/bridge/package.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { workbookIo } from "$lib/bridge/workbook_io.svelte";
  import { memorySources } from "$lib/bridge/memory_sources.svelte";
  import ContextMenu from "./ContextMenu.svelte";

  // Workspace-scoped file tree: shows every Package inside the active
  // top-level Workspace. The active Package is highlighted but not the
  // exclusive scope (IDE explorer behavior — all packages visible).
  //
  // View mode persists per-package on the currently-active one for
  // historical reasons (D14). When no package is active, it falls back
  // to "source".
  const viewMode = $derived<ViewMode>(packageStore.active?.view_mode ?? "source");
  const isCompiledView = $derived(viewMode === "compiled");

  // Lazy-loaded full Package records for every name in the active
  // workspace. Refreshes whenever the workspace's package_names list
  // changes; mutations to a Package's folders (add/remove) propagate
  // via workspace-scope-change events the packageStore already handles.
  let packageData = $state<Record<string, PackageDef>>({});
  $effect(() => {
    const names = workspaces.active?.package_names ?? [];
    for (const name of names) {
      if (!packageData[name]) {
        packageStore
          .load(name)
          .then((p) => (packageData = { ...packageData, [name]: p }))
          .catch(() => {});
      }
    }
    // Drop entries for packages no longer in the workspace.
    const kept: Record<string, PackageDef> = {};
    for (const n of names) if (packageData[n]) kept[n] = packageData[n];
    if (Object.keys(kept).length !== Object.keys(packageData).length) {
      packageData = kept;
    }
  });

  // The active package always uses its live data (folders may have
  // changed via the rail "+ New package" flow); other packages use the
  // lazy-loaded snapshot.
  function pkgFor(name: string): PackageDef | null {
    if (packageStore.active?.name === name) return packageStore.active;
    return packageData[name] ?? null;
  }

  // All folders across all packages in the active workspace — what we
  // ask the fileTree bridge to walk.
  const allFolders = $derived.by<string[]>(() => {
    const out: string[] = [];
    const names = workspaces.active?.package_names ?? [];
    for (const n of names) {
      const p = pkgFor(n);
      if (p) for (const f of p.folders) out.push(f);
    }
    return out;
  });

  // Right-click menu state. The menu opens for one path at a time.
  let menuOpen = $state(false);
  let menuX = $state(0);
  let menuY = $state(0);
  let menuPath = $state<string | null>(null);
  let menuIsDir = $state(false);

  // Track which roots the user has expanded so collapse state survives
  // a re-walk (notify event would otherwise reset to all-collapsed).
  let expandedRoots = $state<Record<string, boolean>>({});
  // Per-directory expand state for nested folders.
  let expandedDirs = $state<Record<string, boolean>>({});

  // Initialise the bridge listener once.
  onMount(() => {
    void fileTree.init();
    // wb-i38o.12 — refresh memory-source list so the dot indicator
    // on .html rows reflects what's actually loaded. Best-effort —
    // the sidecar may not be connected yet; the Settings tab triggers
    // its own refresh when opened.
    void memorySources.refresh();
  });
  onDestroy(() => fileTree.destroy());

  // Reactively sync the bridge's walked roots with every folder across
  // every package in the active workspace. The bridge diffs (drop gone,
  // walk fresh).
  $effect(() => {
    const folders = allFolders;
    fileTree.syncRoots(folders);
    for (const f of folders) {
      if (expandedRoots[f] === undefined) expandedRoots[f] = folders[0] === f;
    }
  });

  // Per-package collapse state — defaults to expanded for the active
  // package, collapsed for the rest. User toggles persist for the
  // session.
  let expandedPkgs = $state<Record<string, boolean>>({});
  function isPkgExpanded(name: string): boolean {
    if (expandedPkgs[name] !== undefined) return expandedPkgs[name];
    return packageStore.active?.name === name;
  }

  // Inline file-tree filter. Distinct from the SearchDrawer — this is
  // a narrow "find file in this tree" scoped to the active workspace's
  // packages. Toggling the search icon swaps the workspace row for an
  // input; clearing collapses back.
  let searchActive = $state(false);
  let searchQuery = $state("");
  let searchInputEl: HTMLInputElement | null = $state(null);

  function openInlineSearch() {
    searchActive = true;
    queueMicrotask(() => searchInputEl?.focus());
  }
  function closeInlineSearch() {
    searchActive = false;
    searchQuery = "";
  }
  function onSearchKey(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      if (searchQuery) {
        searchQuery = "";
      } else {
        closeInlineSearch();
      }
    }
  }

  // Match-mode predicate that includes the inline-search query.
  function matchesSearch(entry: FsEntry): boolean {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return true;
    if (entry.is_dir) return true; // dir visibility handled by descendant match
    return entry.name.toLowerCase().includes(q) || entry.rel.toLowerCase().includes(q);
  }

  function matchesFilter(entry: FsEntry): boolean {
    if (entry.is_dir) return true;
    if (isCompiledView) {
      const lower = entry.name.toLowerCase();
      if (!(lower.endsWith(".html") || lower.endsWith(".htm"))) return false;
    }
    return matchesSearch(entry);
  }

  async function setViewMode(mode: ViewMode) {
    const target = packageStore.active;
    if (!target) return;
    if (target.view_mode === mode) return;
    try {
      await packageStore.setViewMode(target.name, mode);
    } catch (e) {
      console.warn("[fileTree] setViewMode failed", e);
    }
  }

  // Count of .html files visible across every walked root in every
  // package. Drives the "no compiled workbooks" empty state.
  const compiledCount = $derived.by(() => {
    let n = 0;
    for (const root of allFolders) {
      const tree = fileTree.trees[root];
      if (!tree) continue;
      for (const e of tree.entries) {
        if (e.is_dir) continue;
        const l = e.name.toLowerCase();
        if (l.endsWith(".html") || l.endsWith(".htm")) n++;
      }
    }
    return n;
  });

  async function activatePackage(name: string) {
    try {
      await packageStore.setActive(name);
    } catch (e) {
      console.warn("[fileTree] activatePackage failed", e);
    }
  }

  /**
   * Reshape the bridge's flat entry list into a per-root tree, applying
   * the active filter. A directory is kept iff at least one descendant
   * passes the filter (so empty filtered subtrees collapse away).
   */
  type Node = {
    entry: FsEntry;
    children: Node[];
  };

  function buildTree(root: string, entries: FsEntry[]): Node[] {
    // Sort by relative path so parents land before children.
    const sorted = [...entries].sort((a, b) => a.rel.localeCompare(b.rel));
    const byRel = new Map<string, Node>();
    const roots: Node[] = [];
    for (const e of sorted) {
      const node: Node = { entry: e, children: [] };
      byRel.set(e.rel, node);
      const parentRel = e.rel.includes("/")
        ? e.rel.slice(0, e.rel.lastIndexOf("/"))
        : "";
      const parent = parentRel === "" ? null : byRel.get(parentRel);
      if (parent) parent.children.push(node);
      else roots.push(node);
    }

    // Filter: walk depth-first, keep dirs only if they have surviving children.
    // Exception: in source view with `all`, keep empty dirs too (lets
    // users see the workspace skeleton even before any files exist).
    // Compiled view always prunes empty dirs — they're noise.
    const keepEmptyDirs = !isCompiledView;
    function prune(nodes: Node[]): Node[] {
      const kept: Node[] = [];
      for (const n of nodes) {
        if (n.entry.is_dir) {
          const survivors = prune(n.children);
          if (survivors.length > 0 || keepEmptyDirs) {
            kept.push({ entry: n.entry, children: survivors });
          }
        } else if (matchesFilter(n.entry)) {
          kept.push(n);
        }
      }
      // Dirs first, then files; preserves the Rust-side sort.
      kept.sort((a, b) => {
        if (a.entry.is_dir !== b.entry.is_dir) return a.entry.is_dir ? -1 : 1;
        return a.entry.name.localeCompare(b.entry.name);
      });
      return kept;
    }
    void root;
    return prune(roots);
  }

  function rootBasename(root: string): string {
    const parts = root.split("/").filter(Boolean);
    return parts[parts.length - 1] ?? root;
  }

  function onContextMenu(event: MouseEvent, path: string, isDir: boolean) {
    event.preventDefault();
    menuX = event.clientX;
    menuY = event.clientY;
    menuPath = path;
    menuIsDir = isDir;
    menuOpen = true;
  }

  async function copyPath() {
    if (!menuPath) return;
    try {
      await navigator.clipboard.writeText(menuPath);
    } catch (e) {
      console.warn("[fileTree] copy failed", e);
    }
    menuOpen = false;
  }

  async function openInOs() {
    if (!menuPath) return;
    try {
      await fileTree.openInOs(menuPath);
    } catch (e) {
      console.warn("[fileTree] open_in_os failed", e);
    }
    menuOpen = false;
  }

  async function clickFile(path: string) {
    try {
      await fileTree.open(path);
    } catch (e) {
      console.warn("[fileTree] tab_open failed", e);
    }
  }

  // wb-i38o.13 — bundle / unbundle.
  // The "Bundle directory" item is enabled when right-clicking a dir.
  // The "Unbundle workbook" item is enabled when right-clicking a
  // .html / .htm file. We derive the predicate from menuPath each time
  // the menu opens.
  const menuIsHtml = $derived(
    !!menuPath &&
      !menuIsDir &&
      (menuPath.toLowerCase().endsWith(".html") ||
        menuPath.toLowerCase().endsWith(".htm")),
  );
  const bundleInFlight = $derived(
    !!menuPath && menuIsDir && workbookIo.inFlight.has(menuPath),
  );
  const unbundleInFlight = $derived(
    !!menuPath && menuIsHtml && workbookIo.inFlight.has(menuPath),
  );

  async function bundleDir() {
    if (!menuPath || !menuIsDir) return;
    menuOpen = false;
    try {
      await workbookIo.bundle(menuPath);
    } catch (e) {
      console.warn("[fileTree] bundle failed", e);
    }
  }

  async function unbundleWorkbook() {
    if (!menuPath || !menuIsHtml) return;
    menuOpen = false;
    try {
      await workbookIo.unbundle(menuPath);
    } catch (e) {
      console.warn("[fileTree] unbundle failed", e);
    }
  }

  // wb-i38o.12 — load .html workbook into the agent's semantic memory.
  const memoryInFlight = $derived(
    !!menuPath && menuIsHtml && !!memorySources.inFlight[menuPath],
  );
  const memoryAlreadyLoaded = $derived(
    !!menuPath && menuIsHtml && memorySources.isLoaded(menuPath),
  );

  async function loadAsMemory() {
    if (!menuPath || !menuIsHtml) return;
    menuOpen = false;
    try {
      await memorySources.add(menuPath);
    } catch (e) {
      console.warn("[fileTree] load_as_memory failed", e);
    }
  }

  async function removeAsMemory() {
    if (!menuPath || !menuIsHtml) return;
    menuOpen = false;
    try {
      await memorySources.remove(menuPath);
    } catch (e) {
      console.warn("[fileTree] remove_as_memory failed", e);
    }
  }
</script>

<aside class="panel" aria-label="File tree">

  <div class="body">
    {#if !workspaces.active}
      <p class="empty">No active workspace.</p>
    {:else}
      {@const ws = workspaces.active}
      {@const pkgNames = ws.package_names}
      <!-- Top non-collapsible row = the active workspace itself. View
           toggle inline-right. -->
      <div class="ws-row">
        {#if searchActive}
          <Search weight="bold" size={14} />
          <input
            bind:this={searchInputEl}
            bind:value={searchQuery}
            type="text"
            placeholder="Find in {ws.name}…"
            spellcheck="false"
            autocomplete="off"
            onkeydown={onSearchKey}
          />
          <button
            type="button"
            class="row-btn"
            aria-label="Close search"
            title="Close search"
            onclick={closeInlineSearch}
          >
            <X weight="bold" size={14} />
          </button>
        {:else}
          <span class="name" title={ws.name}>{ws.name}</span>
          <button
            type="button"
            class="row-btn"
            aria-label="Find in tree"
            title="Find in tree"
            onclick={openInlineSearch}
          >
            <Search weight="bold" size={14} />
          </button>
          <div
            class="view-toggle"
            role="tablist"
            aria-label="View mode: source vs compiled"
          >
            <button
              class="seg"
              class:active={!isCompiledView}
              role="tab"
              aria-selected={!isCompiledView}
              title="Source"
              disabled={!packageStore.active}
              onclick={() => setViewMode("source")}
            >
              <Code2 weight="fill" size={14} />
            </button>
            <button
              class="seg"
              class:active={isCompiledView}
              role="tab"
              aria-selected={isCompiledView}
              title="Compiled"
              disabled={!packageStore.active}
              onclick={() => setViewMode("compiled")}
            >
              <Package weight="fill" size={14} />
            </button>
          </div>
        {/if}
      </div>

      {#if pkgNames.length === 0}
        <p class="empty small">No packages yet. Add one with "+" in the rail.</p>
      {:else if isCompiledView && compiledCount === 0 && allFolders.every((f) => fileTree.trees[f])}
        <p class="empty small">No compiled workbooks. Bundle <code>.org</code> files via the command palette.</p>
      {:else}
        {#each pkgNames as pkgName (pkgName)}
          {@const pkg = pkgFor(pkgName)}
          {@const isActivePkg = packageStore.active?.name === pkgName}
          {@const pkgOpen = isPkgExpanded(pkgName)}
          {@const folders = pkg?.folders ?? []}
          <details
            class="pkg"
            class:active-pkg={isActivePkg}
            open={pkgOpen}
            ontoggle={(e) => (expandedPkgs[pkgName] = (e.currentTarget as HTMLDetailsElement).open)}
          >
            <summary
              class="pkg-summary"
              onclick={(e) => {
                // Activate on click; <details> still toggles via its
                // own click-on-summary semantics.
                if (!isActivePkg) void activatePackage(pkgName);
              }}
              title={pkgName}
            >
              <img class="mi-tree" src={folderIconUrl(pkgName, pkgOpen)} alt="" />
              <span class="name">{pkgName}</span>
              {#if isActivePkg}<span class="active-dot" aria-label="active"></span>{/if}
            </summary>
            <div class="pkg-body">
              {#if folders.length === 0}
                <p class="empty xs">No folders bound.</p>
              {:else if folders.length === 1 && rootBasename(folders[0]) === pkgName}
                <!-- Flatten the redundant single-folder-matches-name case. -->
                {@const root = folders[0]}
                {@const status = fileTree.status[root]}
                {@const tree = fileTree.trees[root]}
                {#if status === "loading" && !tree}
                  <p class="empty xs">Walking…</p>
                {:else if status === "error"}
                  <p class="empty xs error">{fileTree.errors[root] ?? "walk failed"}</p>
                {:else if tree}
                  {@const nodes = buildTree(root, tree.entries)}
                  {#if nodes.length === 0}
                    <p class="empty xs">No files yet.</p>
                  {:else}
                    {@render renderChildren(nodes, 1)}
                  {/if}
                {/if}
              {:else}
                {#each folders as root (root)}
                  {@const status = fileTree.status[root]}
                  {@const tree = fileTree.trees[root]}
                  {@const isOpen = searchQuery ? true : (expandedRoots[root] ?? false)}
                  <details
                    class="root"
                    open={isOpen}
                    ontoggle={(e) => (expandedRoots[root] = (e.currentTarget as HTMLDetailsElement).open)}
                  >
                    <summary
                      class="root-summary"
                      oncontextmenu={(e) => onContextMenu(e, root, true)}
                      title={root}
                    >
                      <img class="mi-tree" src={folderIconUrl(rootBasename(root), isOpen)} alt="" />
                      <span class="name">{rootBasename(root)}</span>
                      {#if tree?.truncated}
                        <span class="tag" title="Walk hit entry cap; narrow the root">truncated</span>
                      {/if}
                    </summary>
                    <div class="root-body">
                      {#if status === "loading" && !tree}
                        <p class="empty xs">Walking {root}…</p>
                      {:else if status === "error"}
                        <p class="empty xs error">
                          {fileTree.errors[root] ?? "walk failed"}
                        </p>
                      {:else if tree}
                        {@const nodes = buildTree(root, tree.entries)}
                        {#if nodes.length === 0}
                          <p class="empty xs">No files.</p>
                        {:else}
                          {@render renderChildren(nodes, 2)}
                        {/if}
                      {/if}
                    </div>
                  </details>
                {/each}
              {/if}
            </div>
          </details>
        {/each}
      {/if}
    {/if}
  </div>
</aside>

{#snippet renderChildren(nodes: Node[], depth: number)}
  {#each nodes as node (node.entry.path)}
    {#if node.entry.is_dir}
      {@const open = searchQuery ? true : (expandedDirs[node.entry.path] ?? false)}
      <details
        class="dir"
        {open}
        ontoggle={(e) =>
          (expandedDirs[node.entry.path] = (e.currentTarget as HTMLDetailsElement).open)}
      >
        <summary
          class="row dir-row"
          style="padding-left: {depth * 12 + 14}px"
          oncontextmenu={(e) => onContextMenu(e, node.entry.path, true)}
          title={node.entry.path}
        >
          <img class="mi-tree" src={folderIconUrl(node.entry.name, open)} alt="" />
          <span class="name">{node.entry.name}</span>
        </summary>
        {@render renderChildren(node.children, depth + 1)}
      </details>
    {:else}
      {@const lower = node.entry.name.toLowerCase()}
      {@const isHtml = lower.endsWith(".html") || lower.endsWith(".htm")}
      {@const loadedAsMemory =
        isHtml && memorySources.isLoaded(node.entry.path)}
      <button
        class="row file-row"
        style="padding-left: {depth * 12 + 28}px"
        onclick={() => clickFile(node.entry.path)}
        oncontextmenu={(e) => onContextMenu(e, node.entry.path, false)}
        title={loadedAsMemory
          ? `${node.entry.path} — loaded as memory source`
          : node.entry.path}
      >
        <img class="mi-tree" src={fileIconUrl(node.entry.name)} alt="" />
        <span class="name">{node.entry.name}</span>
        {#if loadedAsMemory}
          <span class="memory-dot" aria-label="Loaded as memory source"></span>
        {/if}
      </button>
    {/if}
  {/each}
{/snippet}

<ContextMenu bind:open={menuOpen} x={menuX} y={menuY}>
  <button class="ctx-item" onclick={openInOs}>
    <ExternalLink weight="fill" size={12} />
    Open in OS
  </button>
  <button class="ctx-item" onclick={copyPath}>
    <Copy weight="fill" size={12} />
    Copy path
  </button>
  {#if menuIsDir || menuIsHtml}
    <div class="ctx-sep"></div>
  {/if}
  {#if menuIsDir}
    <!-- wb-i38o.13 — bundle a folder of .org files into a single .html. -->
    <button
      class="ctx-item"
      onclick={bundleDir}
      disabled={bundleInFlight}
      title={menuPath
        ? `Output: ${workbookIo.bundleOutputFor(menuPath)}`
        : ""}
    >
      <Package weight="fill" size={12} />
      {bundleInFlight ? "Bundling…" : "Bundle directory to workbook"}
    </button>
  {/if}
  {#if menuIsHtml}
    <!-- wb-i38o.13 — unbundle .html workbook back to its source files. -->
    <button
      class="ctx-item"
      onclick={unbundleWorkbook}
      disabled={unbundleInFlight}
      title={menuPath
        ? `Output: ${workbookIo.unbundleOutputFor(menuPath)}/`
        : ""}
    >
      <PackageOpen weight="fill" size={12} />
      {unbundleInFlight ? "Unbundling…" : "Unbundle workbook to directory"}
    </button>
    <!-- wb-i38o.12 — add / remove .html workbook as a memory source. -->
    {#if memoryAlreadyLoaded}
      <button
        class="ctx-item"
        onclick={removeAsMemory}
        disabled={memoryInFlight}
        title="Remove this workbook's entries from the agent's memory"
      >
        <Database weight="fill" size={12} />
        {memoryInFlight ? "Removing…" : "Remove as memory source"}
      </button>
    {:else}
      <button
        class="ctx-item"
        onclick={loadAsMemory}
        disabled={memoryInFlight}
        title="Index this workbook's .org files into the agent's semantic memory"
      >
        <Database weight="fill" size={12} />
        {memoryInFlight ? "Loading…" : "Add as memory source"}
      </button>
    {/if}
  {/if}
  <div class="ctx-sep"></div>
  <!-- Deferred per wb-i38o.7 scope. Disabled stubs so the affordance
       is discoverable; tracked as a follow-up. -->
  <button class="ctx-item" disabled title="TODO: wb-i38o.7 follow-up">
    {menuIsDir ? "New file…" : "Rename…"}
  </button>
  <button class="ctx-item" disabled title="TODO: wb-i38o.7 follow-up">
    Delete…
  </button>
</ContextMenu>

<style>
  .panel {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
    background: var(--color-surface);
    color: var(--color-fg);
    font-size: 12.5px;
    border-left: 1px solid var(--color-border);
  }
  /* Top non-collapsible row inside the tree body — the active
   * workspace. Sits at depth 0 with no expander; below it, each
   * Package in the workspace is a collapsible group. */
  .ws-row {
    display: flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.45rem 0.75rem 0.45rem 0.6rem;
    color: var(--color-fg);
    font-size: 0.85rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    border-bottom: 1px solid var(--color-border);
  }
  .mi-tree {
    width: 14px;
    height: 14px;
    display: block;
    flex-shrink: 0;
  }
  .ws-row .name {
    flex: 1 1 auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }

  /* Per-package collapsible group inside the workspace tree. */
  .pkg { border-bottom: 1px solid var(--color-border); }
  .pkg:last-of-type { border-bottom: none; }
  .pkg-summary {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.35rem 0.75rem 0.35rem 0.6rem;
    cursor: pointer;
    list-style: none;
    color: var(--color-fg-muted);
    font-size: 0.8rem;
  }
  .pkg-summary::-webkit-details-marker { display: none; }
  .pkg-summary:hover { background: var(--color-surface-soft); }
  .pkg-summary .name {
    flex: 1 1 auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }
  .pkg.active-pkg > .pkg-summary {
    color: var(--color-fg);
    font-weight: 500;
  }
  .active-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #10b981;
    flex-shrink: 0;
  }
  .pkg-body { padding-left: 0; }
  .empty.xs {
    padding: 0.45rem 0.75rem 0.45rem 1.6rem;
    font-size: 0.75rem;
    color: var(--color-fg-subtle);
    margin: 0;
  }
  .empty.xs.error { color: #ef4444; }

  /* Inline segmented source/compiled toggle on the ws row. The
   * container height must accommodate the 24px `.seg` children; a
   * smaller height clips the 14px icons. */
  .view-toggle {
    display: inline-flex;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    overflow: hidden;
    height: 24px;
    opacity: 0.7;
    transition: opacity 0.12s;
  }
  .ws-row:hover .view-toggle,
  .view-toggle:focus-within { opacity: 1; }

  /* Small inline buttons in the ws row (search-open / close). */
  .row-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    /* Match the titlebar icon-btn sizing so 14px icons sit with the
     * same visual padding here as they do in the chrome above. */
    width: 24px;
    height: 24px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 6px;
    cursor: pointer;
    opacity: 0.7;
    transition: opacity 0.12s, background 0.1s, color 0.1s;
  }
  .ws-row:hover .row-btn { opacity: 1; }
  .row-btn:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  /* Inline search input — replaces the ws name when active. */
  .ws-row input {
    flex: 1 1 auto;
    background: transparent;
    border: 0;
    outline: 0;
    color: var(--color-fg);
    font-family: inherit;
    font-size: 0.82rem;
    font-weight: 500;
    min-width: 0;
    padding: 0;
  }
  .ws-row input::placeholder {
    color: var(--color-fg-subtle);
    font-weight: 400;
  }
  .seg {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    /* Slightly wider than .row-btn so the two-segment toggle reads as
     * one grouped control rather than two stand-alone buttons. */
    width: 26px;
    height: 24px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    cursor: pointer;
    padding: 0;
  }
  .seg + .seg {
    border-left: 1px solid var(--color-border);
  }
  .seg:hover:not(:disabled) { color: var(--color-fg); }
  .seg.active {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .seg:disabled { opacity: 0.5; cursor: not-allowed; }
  .body {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    padding: 0.25rem 0;
  }
  .root {
    border-bottom: 1px solid var(--color-border);
  }
  .root:last-child {
    border-bottom: none;
  }
  .root-summary {
    list-style: none;
    display: flex;
    align-items: center;
    gap: 0.4rem;
    padding: 6px 10px;
    cursor: pointer;
    user-select: none;
    color: var(--color-fg);
    font-weight: 500;
  }
  .root-summary::-webkit-details-marker {
    display: none;
  }
  .root-summary:hover {
    background: var(--color-surface-soft);
  }
  .root-body {
    padding-bottom: 0.25rem;
  }
  .dir > summary {
    list-style: none;
  }
  .dir > summary::-webkit-details-marker {
    display: none;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    width: 100%;
    border: 0;
    background: transparent;
    padding-top: 3px;
    padding-bottom: 3px;
    padding-right: 10px;
    color: var(--color-fg);
    text-align: left;
    cursor: pointer;
    font: inherit;
  }
  .row:hover {
    background: var(--color-surface-soft);
  }
  .dir-row {
    user-select: none;
    cursor: pointer;
  }
  .file-row {
    color: var(--color-fg-muted);
  }
  .file-row:hover {
    color: var(--color-fg);
  }
  .name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }
  .memory-dot {
    flex-shrink: 0;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-accent, #10b981);
    opacity: 0.7;
  }
  .tag {
    font-size: 10px;
    color: var(--color-fg-subtle);
    border: 1px solid var(--color-border);
    border-radius: 3px;
    padding: 0 4px;
  }
  .empty {
    margin: 0;
    padding: 1rem 0.85rem;
    color: var(--color-fg-subtle);
    font-size: 12px;
    line-height: 1.5;
  }
  .empty.small {
    padding: 0.4rem 1.2rem;
    font-size: 11.5px;
  }
  .empty.error {
    color: var(--color-fg-muted);
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .empty code {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
  }
</style>
