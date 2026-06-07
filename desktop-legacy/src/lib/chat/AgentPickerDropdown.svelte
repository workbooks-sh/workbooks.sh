<script lang="ts">
  /**
   * AgentPickerDropdown — chat-header picker for the active agent.
   * Studio-inspired chrome (archive/studio/.../AgentPicker.svelte):
   * tight 28px trigger, 22px row icons, tagline as muted subtext,
   * dashed "+ Add agent" at the bottom.
   *
   * Workbooks Desktop doesn't have group / personal taxonomies yet,
   * so the catalog is one flat section. When agents-by-group lands,
   * adding section heads + buckets between the trigger and the
   * "+ Add agent" row is the natural extension point.
   */
  import {
    ChevronDown,
    ChevronRight,
    Folder,
    Plus,
    Pencil,
    FileText,
    Clipboard,
    MoreHorizontal,
  } from "@lucide/svelte";
  import { tick } from "svelte";
  import { agents, type AgentCatalogEntry } from "$lib/bridge/agents.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { tabs } from "$lib/tabs/store.svelte";
  import AgentIcon from "./AgentIcon.svelte";

  /** Picker tree node. A `folder` node groups agents by on-disk
   *  subdirectory; an `agent` node represents a single agent and may
   *  carry its own `:agent:`-nested in-file children. Both render
   *  with a twirl-down disclosure and inherit picker selection
   *  semantics. */
  type FolderNode = {
    kind: "folder";
    name: string;
    children: PickerNode[];
  };
  type AgentNode = {
    kind: "agent";
    agent: AgentCatalogEntry;
    children: AgentNode[];
  };
  type PickerNode = FolderNode | AgentNode;

  let {
    oncreate,
  }: {
    oncreate: () => void;
  } = $props();

  let copyConfirm = $state(false);

  let triggerEl = $state<HTMLButtonElement | null>(null);
  let menuEl = $state<HTMLDivElement | null>(null);
  let open = $state(false);
  let highlight = $state(0);

  // Per-row context menu. `moreFor` is the slug of the row whose
  // ⋯ button is currently active; `moreAt` is the fixed-position
  // anchor (right edge of that button) so the popover doesn't get
  // clipped by the dropdown's scroll overflow. moreFor === null
  // means "no row menu is open".
  let moreFor = $state<string | null>(null);
  let moreAt = $state<{ top: number; right: number } | null>(null);
  let moreEl = $state<HTMLDivElement | null>(null);

  const moreAgent = $derived(
    moreFor ? agents.agents.find((a) => a.slug === moreFor) ?? null : null,
  );

  const selected = $derived(agents.selectedEntry);

  // Sort: alphabetical by title for both folders and agents.
  const sortedAgents = $derived<AgentCatalogEntry[]>(
    [...agents.agents].sort((a, b) =>
      (a.title ?? a.slug).localeCompare(b.title ?? b.slug),
    ),
  );

  /** Build the picker tree:
   *  1. Group by `folder` (the on-disk subdir under `<scope>/agents/`).
   *  2. Within each folder bucket, nest in-file children under their
   *     parent agent via `parent_id`.
   *  Folders default to expanded; nested in-file children expand
   *  per-parent toggle. */
  const tree = $derived<PickerNode[]>(buildTree(sortedAgents));

  function buildTree(list: AgentCatalogEntry[]): PickerNode[] {
    // Step 1: bucket by folder path (top-level folders only — we
    // collapse multi-segment paths under their first segment to keep
    // the picker shallow. Sub-folders nest as expected because the
    // recursion below splits on slashes if/when present).
    const byFolder = new Map<string, AgentCatalogEntry[]>();
    for (const a of list) {
      const f = a.folder ?? "";
      if (!byFolder.has(f)) byFolder.set(f, []);
      byFolder.get(f)!.push(a);
    }

    // Build agent-tree for a single folder's agents: pick out
    // parent_id == null as roots, attach the rest as children.
    function agentTree(entries: AgentCatalogEntry[]): AgentNode[] {
      const bySlug = new Map<string, AgentNode>();
      for (const a of entries) {
        bySlug.set(a.slug, { kind: "agent", agent: a, children: [] });
      }
      const roots: AgentNode[] = [];
      for (const a of entries) {
        const node = bySlug.get(a.slug)!;
        const pid = a.parent_id ?? null;
        const parent = pid ? bySlug.get(pid) : null;
        if (parent) parent.children.push(node);
        else roots.push(node);
      }
      return roots;
    }

    const out: PickerNode[] = [];
    // Root-level (no folder) agents come first.
    const rootEntries = byFolder.get("") ?? [];
    for (const node of agentTree(rootEntries)) out.push(node);
    // Then folder nodes, alphabetical by name.
    const folderNames = [...byFolder.keys()].filter((k) => k !== "").sort();
    for (const name of folderNames) {
      const entries = byFolder.get(name)!;
      out.push({
        kind: "folder",
        name,
        children: agentTree(entries),
      });
    }
    return out;
  }

  /** Flat list of agent entries in render order, used for arrow-key
   *  navigation. Folders are pass-through (children render inline);
   *  collapsed branches are excluded. */
  const flatVisible = $derived<AgentCatalogEntry[]>(flatten(tree));

  function flatten(nodes: PickerNode[]): AgentCatalogEntry[] {
    const acc: AgentCatalogEntry[] = [];
    function walk(n: PickerNode) {
      if (n.kind === "folder") {
        if (!collapsed[`folder:${n.name}`]) n.children.forEach(walk);
      } else {
        acc.push(n.agent);
        if (!collapsed[`agent:${n.agent.slug}`]) n.children.forEach(walk);
      }
    }
    nodes.forEach(walk);
    return acc;
  }

  /** Disclosure state. Keys: `folder:<name>` and `agent:<slug>`.
   *  Default: all expanded. */
  let collapsed = $state<Record<string, boolean>>({});

  function toggleCollapse(key: string) {
    collapsed = { ...collapsed, [key]: !collapsed[key] };
  }

  async function toggle(e: MouseEvent) {
    e.stopPropagation();
    open = !open;
    if (open) {
      highlight = Math.max(
        0,
        flatVisible.findIndex((a) => a.slug === agents.selected),
      );
      await tick();
    }
  }

  function pick(a: AgentCatalogEntry) {
    agents.select(a.slug);
    open = false;
  }

  function pickCreate() {
    open = false;
    oncreate();
  }

  // ── per-row context menu ──────────────────────────────────────
  // Each row's ⋯ button opens a popover whose actions target THAT
  // row's agent — not the globally-selected one. Anchoring is
  // position:fixed so the popover escapes the dropdown's scroll
  // container.

  function openMore(e: MouseEvent, slug: string) {
    e.stopPropagation();
    const btn = e.currentTarget as HTMLElement;
    const rect = btn.getBoundingClientRect();
    moreAt = { top: rect.bottom + 4, right: window.innerWidth - rect.right };
    moreFor = slug;
  }
  function closeMore() {
    moreFor = null;
    moreAt = null;
  }

  function gotoEdit(slug: string) {
    closeMore();
    open = false;
    // Edit always goes to the Agents settings tab; the editor picks
    // up the slug from the active selection. Select the row first
    // so the editor opens that agent, not whatever was selected
    // before clicking ⋯.
    agents.select(slug);
    chrome.navigateTo("settings", "agents");
  }

  function viewSource(a: AgentCatalogEntry | null) {
    closeMore();
    open = false;
    if (a?.path) tabs.open(a.path);
  }

  async function copySlug(slug: string) {
    closeMore();
    try {
      await navigator.clipboard.writeText(slug);
      copyConfirm = true;
      setTimeout(() => (copyConfirm = false), 1200);
    } catch {
      // Browser denied clipboard — silent.
    }
  }

  $effect(() => {
    if (!open) return;
    function away(e: MouseEvent) {
      const t = e.target as Node;
      // When the per-row menu is open, an outside click should only
      // close that menu — not the whole dropdown. The dropdown stays
      // up so the user can pop another row's menu without re-opening.
      if (moreEl?.contains(t)) return;
      if (moreFor !== null) {
        closeMore();
        return;
      }
      if (menuEl?.contains(t) || triggerEl?.contains(t)) return;
      open = false;
    }
    function key(e: KeyboardEvent) {
      if (!open) return;
      if (e.key === "Escape") {
        if (moreFor !== null) closeMore();
        else open = false;
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        highlight = Math.min(highlight + 1, flatVisible.length);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        highlight = Math.max(highlight - 1, 0);
      } else if (e.key === "Enter") {
        e.preventDefault();
        if (highlight < flatVisible.length) pick(flatVisible[highlight]);
        else pickCreate();
      }
    }
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", key);
    };
  });
</script>

{#snippet renderNodes(nodes: PickerNode[], depth: number)}
  {#each nodes as node, idx (node.kind === "folder" ? `f:${node.name}` : `a:${node.agent.slug}`)}
    {#if node.kind === "folder"}
      {@const collapsedKey = `folder:${node.name}`}
      {@const isCollapsed = collapsed[collapsedKey]}
      <div class="folder-node" style:--indent="{depth * 12}px">
        <button
          type="button"
          class="folder-row"
          onclick={() => toggleCollapse(collapsedKey)}
          aria-expanded={!isCollapsed}
        >
          {#if isCollapsed}
            <ChevronRight size={12} strokeWidth={2} class="twirl" aria-hidden="true" />
          {:else}
            <ChevronDown size={12} strokeWidth={2} class="twirl" aria-hidden="true" />
          {/if}
          <Folder size={12} strokeWidth={1.8} class="folder-glyph" aria-hidden="true" />
          <span class="folder-name">{node.name}</span>
        </button>
        {#if !isCollapsed}
          {@render renderNodes(node.children, depth + 1)}
        {/if}
      </div>
    {:else}
      {@const a = node.agent}
      {@const flatIdx = flatVisible.findIndex((x) => x.slug === a.slug)}
      {@const hasKids = node.children.length > 0}
      {@const childKey = `agent:${a.slug}`}
      {@const kidsCollapsed = collapsed[childKey]}
      <div
        class="row-wrap"
        class:selected={a.slug === agents.selected}
        class:active={flatIdx === highlight}
        style:--indent="{depth * 12}px"
      >
        {#if hasKids}
          <button
            type="button"
            class="kid-twirl"
            onclick={(e) => {
              e.stopPropagation();
              toggleCollapse(childKey);
            }}
            aria-label={kidsCollapsed ? "Expand children" : "Collapse children"}
            aria-expanded={!kidsCollapsed}
          >
            {#if kidsCollapsed}
              <ChevronRight size={12} strokeWidth={2} aria-hidden="true" />
            {:else}
              <ChevronDown size={12} strokeWidth={2} aria-hidden="true" />
            {/if}
          </button>
        {:else}
          <span class="kid-twirl placeholder" aria-hidden="true"></span>
        {/if}
        <button
          type="button"
          role="option"
          class="row"
          aria-selected={a.slug === agents.selected}
          onclick={() => pick(a)}
          onmouseenter={() => (highlight = flatIdx)}
        >
          <span class="row-icon" aria-hidden="true">
            <AgentIcon
              icon={a.icon}
              title={a.title}
              slug={a.slug}
              size={18}
            />
          </span>
          <span class="row-body">
            <span class="row-title">{a.title ?? a.slug}</span>
            {#if a.tagline}
              <span class="row-tag">{a.tagline}</span>
            {/if}
          </span>
          {#if a.parse_error}
            <span class="err-chip">parse error</span>
          {/if}
        </button>
        <button
          type="button"
          class="more-btn"
          class:open={moreFor === a.slug}
          title="More actions"
          aria-label="More actions for {a.title ?? a.slug}"
          aria-haspopup="menu"
          aria-expanded={moreFor === a.slug}
          onclick={(e) => openMore(e, a.slug)}
        >
          <MoreHorizontal size={14} strokeWidth={2} aria-hidden="true" />
        </button>
      </div>
      {#if hasKids && !kidsCollapsed}
        {@render renderNodes(node.children, depth + 1)}
      {/if}
    {/if}
  {/each}
{/snippet}

<div class="picker">
  <button
    type="button"
    bind:this={triggerEl}
    class="trigger"
    onclick={toggle}
    aria-haspopup="listbox"
    aria-expanded={open}
    title={selected?.tagline ?? selected?.title ?? ""}
  >
    <span class="t-icon" aria-hidden="true">
      {#if selected}
        <AgentIcon
          icon={selected.icon}
          title={selected.title}
          slug={selected.slug}
          size={16}
        />
      {/if}
    </span>
    <span class="t-title">{selected?.title ?? "Pick an agent"}</span>
    <ChevronDown size={12} strokeWidth={2} class="chev" aria-hidden="true" />
  </button>

  {#if open}
    <div
      bind:this={menuEl}
      class="menu"
      role="listbox"
      onclick={(e) => e.stopPropagation()}
    >
      {#if tree.length === 0}
        <div class="empty">No agents in the catalog.</div>
      {:else}
        {@render renderNodes(tree, 0)}
      {/if}
      <div class="add-row">
        <button
          type="button"
          class="row add"
          class:active={highlight === flatVisible.length}
          onclick={pickCreate}
          onmouseenter={() => (highlight = flatVisible.length)}
        >
          <span class="row-icon dashed" aria-hidden="true">
            <Plus size={12} strokeWidth={2} />
          </span>
          <span class="add-label">Add agent</span>
        </button>
      </div>

    </div>
  {/if}
</div>

<!-- Per-row context menu. position:fixed so it escapes the dropdown's
     scroll container; anchor coords come from the row's ⋯ button. -->
{#if moreFor && moreAt && moreAgent}
  <div
    bind:this={moreEl}
    class="more-menu"
    role="menu"
    style="top: {moreAt.top}px; right: {moreAt.right}px;"
  >
    <button type="button" class="action" role="menuitem" onclick={() => gotoEdit(moreFor!)}>
      <Pencil size={12} strokeWidth={1.8} aria-hidden="true" />
      <span>Edit agent</span>
    </button>
    <button
      type="button"
      class="action"
      role="menuitem"
      disabled={!moreAgent.path}
      onclick={() => viewSource(moreAgent)}
    >
      <FileText size={12} strokeWidth={1.8} aria-hidden="true" />
      <span>View source</span>
    </button>
    <button type="button" class="action" role="menuitem" onclick={() => copySlug(moreFor!)}>
      <Clipboard size={12} strokeWidth={1.8} aria-hidden="true" />
      <span>Copy slug</span>
    </button>
  </div>
{/if}

{#if copyConfirm}
  <div class="copy-toast" role="status">slug copied</div>
{/if}

<style>
  .picker {
    position: relative;
    display: inline-block;
  }
  .trigger {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    height: 28px;
    padding: 0 0.5rem 0 0.3rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 5px;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    text-align: left;
    max-width: 260px;
    min-width: 0;
  }
  .trigger:hover {
    border-color: var(--color-fg-subtle);
  }
  .t-icon {
    display: inline-flex;
    width: 20px;
    height: 20px;
    align-items: center;
    justify-content: center;
    border-radius: 4px;
    background: var(--color-surface-soft);
    flex: 0 0 20px;
    font-size: 12px;
    font-weight: 600;
  }
  .t-title {
    font-weight: 600;
    font-size: 12.5px;
    line-height: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1 1 auto;
    min-width: 0;
  }
  :global(.trigger .chev) {
    color: var(--color-fg-subtle);
    margin-left: 0.125rem;
    flex-shrink: 0;
  }
  .menu {
    position: absolute;
    top: calc(100% + 6px);
    left: 0;
    width: 320px;
    max-height: 70vh;
    overflow-y: auto;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    box-shadow: var(--shadow-pop, 0 8px 24px rgba(0, 0, 0, 0.3));
    padding: 0.375rem;
    z-index: 50;
  }
  .empty {
    padding: 0.7rem 0.6rem;
    color: var(--color-fg-muted);
    font-size: 12.5px;
  }
  /* The row + its trailing ⋯ live in a flex wrapper so the icon
   *  button is positioned at the row's right edge but isn't part
   *  of the same <button> (nested interactives = a11y mess). */
  .row-wrap {
    position: relative;
    display: flex;
    align-items: stretch;
    border-radius: 5px;
    padding-left: var(--indent, 0);
    /* The ⋯ button only appears on hover/focus — keep the row
     *  visually quiet at rest. */
  }
  /* Folder node — twirl + folder glyph + label. Click toggles
   *  collapse; not selectable (folders aren't agents). */
  .folder-node {
    display: contents;
  }
  .folder-row {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.3rem 0.5rem;
    padding-left: calc(var(--indent, 0) + 0.5rem);
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 11.5px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    cursor: pointer;
    border-radius: 5px;
    width: 100%;
    text-align: left;
  }
  .folder-row:hover {
    color: var(--color-fg);
    background: var(--color-surface-soft);
  }
  :global(.folder-row .twirl) {
    color: var(--color-fg-subtle);
  }
  :global(.folder-row .folder-glyph) {
    color: var(--color-fg-subtle);
  }
  .folder-name {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  /* Per-row twirl for agents with in-file children. Reserves a
   *  fixed-width slot so rows with + without children align. */
  .kid-twirl {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    flex: 0 0 16px;
    background: transparent;
    border: 0;
    padding: 0;
    color: var(--color-fg-subtle);
    cursor: pointer;
    align-self: center;
  }
  .kid-twirl.placeholder {
    cursor: default;
  }
  .kid-twirl:hover:not(.placeholder) {
    color: var(--color-fg);
  }
  .row-wrap:hover,
  .row-wrap.active {
    background: var(--color-surface-soft);
  }
  .row-wrap.selected {
    background: var(--color-surface-soft);
    outline: 1px solid var(--color-border);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    flex: 1 1 auto;
    min-width: 0;
    text-align: left;
    padding: 0.4rem 0.5rem;
    border: 0;
    background: transparent;
    border-radius: 5px;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
  }
  .more-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    flex: 0 0 26px;
    margin-right: 0.15rem;
    background: transparent;
    border: 0;
    color: var(--color-fg-subtle);
    cursor: pointer;
    border-radius: 4px;
    opacity: 0;
    transition: opacity 0.1s, color 0.1s, background 0.1s;
  }
  .row-wrap:hover .more-btn,
  .row-wrap.selected .more-btn,
  .more-btn:focus-visible,
  .more-btn.open {
    opacity: 1;
  }
  .more-btn:hover,
  .more-btn.open {
    color: var(--color-fg);
    background: var(--color-border);
  }
  .row-icon {
    display: inline-flex;
    width: 22px;
    height: 22px;
    align-items: center;
    justify-content: center;
    flex: 0 0 22px;
    background: var(--color-surface-soft);
    border-radius: 5px;
    border: 1px solid var(--color-border);
    overflow: hidden;
  }
  .row-body {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
    gap: 1px;
  }
  .row-title {
    font-size: 13px;
    font-weight: 600;
    line-height: 1.25;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-tag {
    font-size: 11.5px;
    color: var(--color-fg-muted);
    line-height: 1.3;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .err-chip {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 0.05em 0.4em;
    border-radius: 3px;
    background: rgba(252, 165, 165, 0.18);
    color: #fca5a5;
    flex-shrink: 0;
  }
  .add-row {
    margin-top: 0.35rem;
    padding-top: 0.35rem;
    border-top: 1px solid var(--color-border);
  }
  .row.add {
    color: var(--color-fg-muted);
  }
  .row.add:hover,
  .row.add.active {
    color: var(--color-fg);
  }
  .row-icon.dashed {
    background: transparent;
    border: 1px dashed var(--color-border);
    color: var(--color-fg-muted);
  }
  .add-label {
    font-size: 12.5px;
    font-weight: 500;
  }

  /* Per-row context menu (position: fixed; sits above the dropdown
   * scroll container). */
  .more-menu {
    position: fixed;
    min-width: 160px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    box-shadow: var(--shadow-pop, 0 8px 24px rgba(0, 0, 0, 0.3));
    padding: 0.25rem;
    z-index: 60;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .action {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    width: 100%;
    text-align: left;
    padding: 0.35rem 0.5rem;
    border: 0;
    background: transparent;
    border-radius: 5px;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 12.5px;
    cursor: pointer;
  }
  .action:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .action:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .copy-toast {
    position: fixed;
    bottom: 2rem;
    left: 50%;
    transform: translateX(-50%);
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 0.78rem;
    padding: 0.4rem 0.9rem;
    border-radius: 999px;
    z-index: 1300;
    pointer-events: none;
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.25);
  }
</style>
