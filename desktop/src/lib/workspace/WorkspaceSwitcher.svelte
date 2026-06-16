<script lang="ts">
  /**
   * WorkspaceSwitcher — popover anchored next to the rail's top button.
   * Shows: list of workspaces (with icon + name + active checkmark),
   * "+ Create new" item at the bottom. Click outside closes it.
   *
   * "Create new" expands inline into a name + emoji form (no nested
   * modal) so the popover stays cohesive.
   *
   * Per docs/canonical-model.md.
   */
  import { Check, Plus, DotsThree, PencilSimple, UsersThree, SignOut } from "phosphor-svelte";
  import { workspaces, type Workspace } from "$lib/bridge/workspaces.svelte";
  import { onboarding } from "$lib/onboarding/onboarding.svelte";
  import { DEMO_WORKSPACES, DEMO_ACTIVE_WORKSPACE } from "$lib/onboarding/demo";
  import IconPickerMenu from "./IconPickerMenu.svelte";
  import { iconAccent, accentFill, isImageIcon } from "$lib/ui/iconAccent.svelte";
  import { orgs } from "$lib/bridge/orgs.svelte";
  import ShareOrgModal from "$lib/network/components/ShareOrgModal.svelte";

  // During the tour the store is empty — show the demo workspaces so the
  // dropdown is populated like the rest of the demo content.
  const wsItems = $derived(onboarding.active ? DEMO_WORKSPACES : workspaces.workspaces);
  const activeWsId = $derived(
    onboarding.active ? DEMO_ACTIVE_WORKSPACE.id : (workspaces.active?.id ?? null),
  );

  let {
    /** Anchor element (the rail switch button). Used to position the
     *  popover next to it. */
    anchor,
    open = $bindable(false),
  }: {
    anchor: HTMLElement | null;
    open: boolean;
  } = $props();

  let mode = $state<"list" | "create">("list");
  let newName = $state("");
  let newIcon = $state("✨");
  let editId = $state<string | null>(null); // set when the create-form is reused to rename
  let busy = $state(false);
  let error = $state<string | null>(null);
  let popoverEl: HTMLDivElement | undefined = $state();

  // Per-row "⋯" actions menu (Edit / Share / Leave). Permissions aren't modelled yet
  // (workspaces are local), so all show; Share is offered only in a cloud nexus.
  let rowMenuId = $state<string | null>(null);
  let shareWs = $state<{ id: string; name: string } | null>(null);
  const canShare = $derived(!orgs.activeEntry.personal);

  function toggleRowMenu(e: MouseEvent, id: string) {
    e.stopPropagation();
    rowMenuId = rowMenuId === id ? null : id;
  }
  // The ⋯ menu is hidden during onboarding, so these only ever receive real
  // workspaces — accept the minimal shape both Workspace + DemoWorkspace share.
  function startEdit(w: { id: string; name: string; icon: string }) {
    rowMenuId = null;
    editId = w.id;
    newName = w.name;
    newIcon = w.icon || "✨";
    mode = "create"; // the create-form doubles as the rename form
  }
  function shareWorkspace(w: { id: string; name: string }) {
    rowMenuId = null;
    shareWs = { id: w.id, name: w.name };
  }
  async function leaveWorkspace(w: { id: string; name: string }) {
    rowMenuId = null;
    if (!confirm(`Remove "${w.name}" from your workspaces? Its folders stay on disk.`)) return;
    try {
      await workspaces.delete(w.id);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  function initials(name: string): string {
    const words = name.trim().split(/[\s\-_]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return (name || "?").slice(0, 2).toUpperCase();
  }

  async function pick(w: { id: string }) {
    if (onboarding.active) {
      open = false; // demo workspaces aren't real to switch to
      return;
    }
    try {
      await workspaces.setActive(w.id);
      open = false;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  async function commitCreate() {
    const n = newName.trim();
    if (!n) return;
    busy = true;
    error = null;
    try {
      if (editId) {
        await workspaces.rename(editId, n);
        await workspaces.setIcon(editId, newIcon);
      } else {
        const w = await workspaces.create(n, newIcon);
        await workspaces.setActive(w.id);
      }
      editId = null;
      newName = "";
      newIcon = "✨";
      mode = "list";
      open = false;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  function onDocClick(e: MouseEvent) {
    if (!open) return;
    const t = e.target as Node;
    if (popoverEl && popoverEl.contains(t)) return;
    if (anchor && anchor.contains(t)) return;
    open = false;
  }

  function onKey(e: KeyboardEvent) {
    if (open && e.key === "Escape") {
      open = false;
    }
  }

  // Position relative to the anchor. Two placements:
  //  • rail (Sidebar): fly out to the RIGHT of the anchor.
  //  • titlebar (Shelf): the anchor sits in the title bar, so dropping the menu
  //    at the anchor's TOP tucks it behind the bar. Detect a near-top anchor and
  //    drop BELOW it instead, left-aligned — so it's never occluded.
  let style = $derived.by(() => {
    if (!anchor) return "";
    const r = anchor.getBoundingClientRect();
    const inTitlebar = r.top < 48;
    if (inTitlebar) {
      return `top: ${Math.round(r.bottom + 6)}px; left: ${Math.round(r.left)}px;`;
    }
    return `top: ${Math.round(r.top)}px; left: ${Math.round(r.right + 8)}px;`;
  });
</script>

<svelte:window onmousedown={onDocClick} onkeydown={onKey} />

{#if open}
  <div
    class="popover"
    bind:this={popoverEl}
    role="dialog"
    aria-label="Switch workspace"
    {style}
  >
    {#if mode === "list"}
      <div class="list">
        {#each wsItems as w (w.id)}
          {@const isActive = activeWsId === w.id}
          {@const ac = iconAccent(w.icon)}
          <div class="row-wrap" class:menu-open={rowMenuId === w.id}>
            <button
              type="button"
              class="row"
              class:active={isActive}
              onclick={() => pick(w)}
            >
              <span
                class="row-icon"
                class:has-image={w.icon.startsWith("data:image/")}
                class:has-accent={!!ac && !isImageIcon(w.icon)}
                style={ac && !isImageIcon(w.icon)
                  ? `border-color: ${ac}; background: ${accentFill(ac, 0.12)};`
                  : ""}
              >
                {#if w.icon.startsWith("data:image/")}
                  <img src={w.icon} alt="" />
                {:else if w.icon}
                  {w.icon}
                {:else}
                  {initials(w.name)}
                {/if}
              </span>
              <span class="row-name">{w.name}</span>
              {#if isActive}<Check weight="bold" size={12} />{/if}
            </button>
            {#if !onboarding.active}
              <button
                type="button"
                class="more"
                aria-label="Workspace actions"
                onclick={(e) => toggleRowMenu(e, w.id)}
              >
                <DotsThree weight="bold" size={16} />
              </button>
            {/if}
            {#if rowMenuId === w.id}
              <div class="row-menu" role="menu">
                <button type="button" class="mi" onclick={() => startEdit(w)}>
                  <PencilSimple size={13} weight="fill" /> Edit
                </button>
                {#if canShare}
                  <button type="button" class="mi" onclick={() => shareWorkspace(w)}>
                    <UsersThree size={13} weight="fill" /> Share
                  </button>
                {/if}
                <button type="button" class="mi danger" onclick={() => leaveWorkspace(w)}>
                  <SignOut size={13} weight="fill" /> Leave
                </button>
              </div>
            {/if}
          </div>
        {/each}
        <button
          type="button"
          class="row create"
          onclick={() => { editId = null; newName = ""; newIcon = "✨"; mode = "create"; }}
        >
          <span class="row-icon plus"><Plus weight="bold" size={14} /></span>
          <span class="row-name">New workspace</span>
        </button>
      </div>
    {:else}
      <div class="create-form">
        <div class="emoji-row">
          <IconPickerMenu bind:value={newIcon} name={newName || "Workspace"} size={56} />
        </div>
        <form onsubmit={(e) => { e.preventDefault(); commitCreate(); }}>
          <input
            type="text"
            placeholder="Workspace name"
            bind:value={newName}
            autofocus
            disabled={busy}
          />
          <div class="form-row">
            <button
              type="button"
              class="btn ghost"
              onclick={() => { mode = "list"; editId = null; }}
              disabled={busy}
            >
              Back
            </button>
            <button
              type="submit"
              class="btn primary"
              disabled={busy || !newName.trim()}
            >
              {editId ? "Save" : "Create"}
            </button>
          </div>
        </form>
        {#if error}<div class="error">{error}</div>{/if}
      </div>
    {/if}
  </div>
{/if}

{#if shareWs}
  <ShareOrgModal
    resourceId={`workspace:${shareWs.id}`}
    resourceTitle={shareWs.name}
    onclose={() => (shareWs = null)}
  />
{/if}

<style>
  .popover {
    position: fixed;
    z-index: 500;
    min-width: 240px;
    max-width: 320px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-pop);
    padding: 0.4rem;
    color: var(--color-fg);
  }

  .list {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    width: 100%;
    padding: 0.4rem 0.5rem;
    background: transparent;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
    font-size: 0.85rem;
    font-family: inherit;
    color: var(--color-fg);
    text-align: left;
  }
  .row:hover { background: var(--color-surface-soft); }
  .row.active { font-weight: 500; }
  .row.create {
    color: var(--color-fg-muted);
    border-top: 1px solid var(--color-border);
    margin-top: 0.3rem;
    padding-top: 0.5rem;
    border-radius: 0 0 6px 6px;
  }
  .row.create:hover { color: var(--color-fg); }
  .row-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 6px;
    /* Plain — no background, no stroke. Matches the rail's stripped
     * workspace + package treatment. The glyph carries the identity;
     * the box was visual noise. */
    background: transparent;
    border: 0;
    font-size: 14px;
    flex-shrink: 0;
    overflow: hidden;
  }
  .row-icon.has-image { background: transparent; border: 0; }
  /* Accent class still applied by the inline tileStyle from above
   * but neutralised here so the inline border-color + background
   * have no visual effect. Keeps the accent computation around in
   * case we want it later. */
  .row-icon.has-accent {
    border: 0;
    background: transparent !important;
  }
  .row-icon img { width: 100%; height: 100%; object-fit: cover; }
  .row-icon.plus {
    background: transparent;
    color: var(--color-fg-muted);
  }
  .row-name {
    flex: 1 1 auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* Per-row "⋯" actions (Edit / Share / Leave) */
  .row-wrap { position: relative; display: flex; align-items: center; }
  .row-wrap .row { flex: 1 1 auto; min-width: 0; }
  .more {
    flex: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    margin-right: 2px;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: var(--color-fg-muted);
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.12s, background 0.12s, color 0.12s;
  }
  .row-wrap:hover .more,
  .row-wrap.menu-open .more { opacity: 1; }
  .more:hover { background: var(--color-surface-soft); color: var(--color-fg); }
  .row-menu {
    position: absolute;
    top: 100%;
    right: 4px;
    z-index: 10;
    min-width: 132px;
    margin-top: 2px;
    padding: 3px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    box-shadow: var(--shadow-pop);
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .mi {
    display: flex;
    align-items: center;
    gap: 7px;
    width: 100%;
    padding: 6px 8px;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--color-fg);
    font-size: 0.82rem;
    font-family: inherit;
    cursor: pointer;
    text-align: left;
  }
  .mi:hover { background: var(--color-surface-soft); }
  .mi.danger { color: var(--color-err); }

  .create-form {
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
    padding: 0.4rem;
  }
  .emoji-row {
    display: flex;
    justify-content: center;
  }
  form {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  input {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 0.4rem 0.55rem;
    font-size: 0.85rem;
    font-family: inherit;
    color: var(--color-fg);
    outline: 0;
    transition: border-color 0.15s;
  }
  input:focus { border-color: var(--color-border-strong); }
  .form-row {
    display: flex;
    gap: 0.35rem;
  }
  .btn {
    flex: 1 1 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.3rem;
    height: 30px;
    border-radius: 8px;
    font-size: 0.82rem;
    font-weight: 500;
    font-family: var(--font-mono);
    cursor: pointer;
    border: 1px solid transparent;
    transition:
      color 0.15s,
      background 0.15s,
      border-color 0.15s,
      filter 0.15s,
      transform 0.35s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.primary:hover:not(:disabled) {
    filter: brightness(1.08);
    transform: translateY(-1px);
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover { color: var(--color-fg); border-color: var(--color-border-strong); }

  .error {
    font-size: 0.78rem;
    color: var(--color-err);
    word-break: break-word;
  }
</style>
