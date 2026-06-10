<script lang="ts">
  /**
   * GroupsTab — list + create groups (wb-u2o0.3.4).
   *
   * Hits /v1/network/groups for the list; clicking opens a group
   * detail view (members + manage). Top-right has a "Create group"
   * button that opens a small inline modal.
   */
  import { onMount } from "svelte";
  import { fly, slide, fade } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { Plus, X, Trash as Trash2, Crown, ShieldCheckered as ShieldHalf, UserPlus, CaretLeft as ChevronLeft } from "phosphor-svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import Avatar from "../components/Avatar.svelte";
  import HandleChip from "../components/HandleChip.svelte";
  import EmptyState from "../components/EmptyState.svelte";
  import {
    listGroups, getGroup, createGroup, deleteGroup,
    addGroupMember, removeGroupMember,
    DemoModeError,
    type GroupView, type GroupDetailView, type GroupVisibility,
  } from "../client";

  // ── Listing state ───────────────────────────────────────────────
  let groups = $state<GroupView[]>([]);
  let loading = $state(true);
  let liveMode = $state(false);
  let loadError = $state<string | null>(null);

  // ── Detail / create overlay ─────────────────────────────────────
  let openGroup = $state<GroupDetailView | null>(null);
  let creating = $state(false);

  onMount(load);

  async function load() {
    loading = true;
    loadError = null;
    try {
      const resp = await listGroups();
      groups = resp.groups;
      liveMode = true;
    } catch (e) {
      if (e instanceof DemoModeError) {
        // Sidecar unreachable — empty state.
        groups = [];
        liveMode = false;
      } else {
        // Real failure — clear list + banner with retry.
        groups = [];
        liveMode = true;
        loadError = e instanceof Error ? e.message : String(e);
      }
    } finally {
      loading = false;
    }
  }

  async function openDetail(g: GroupView) {
    if (!liveMode) {
      // No sidecar → no real group data. Show the group's bare summary
      // with an empty member list.
      openGroup = { ...g, members: [] };
      return;
    }
    try {
      openGroup = await getGroup(g.id);
    } catch (e) {
      loadError = e instanceof Error ? e.message : String(e);
    }
  }

  function relTime(ms: number): string {
    const dt = Date.now() - ms;
    if (dt < 86_400_000) return `${Math.round(dt / 3_600_000)}h`;
    if (dt < 7 * 86_400_000) return `${Math.round(dt / 86_400_000)}d`;
    return new Date(ms).toISOString().slice(0, 10);
  }

  // ── Create-group form ──────────────────────────────────────────
  let newName = $state("");
  let newVisibility = $state<GroupVisibility>("private");
  let createSaving = $state(false);
  let createErr = $state<string | null>(null);

  async function submitCreate() {
    if (!newName.trim()) return;
    createSaving = true;
    createErr = null;
    try {
      if (liveMode) {
        const group = await createGroup({ name: newName.trim(), visibility: newVisibility });
        openGroup = group;
      } else {
        // Demo mode: synthesize
        openGroup = {
          id: `demo-${Math.random().toString(36).slice(2, 10)}`,
          name: newName.trim(),
          owner_handle: "me",
          visibility: newVisibility,
          created_at: Date.now(),
          updated_at: Date.now(),
          my_role: "owner",
          members: [{ handle: "me", role: "owner", joined_at: Date.now() }],
        };
      }
      newName = "";
      newVisibility = "private";
      creating = false;
      await load();
    } catch (e) {
      createErr = e instanceof Error ? e.message : String(e);
    } finally {
      createSaving = false;
    }
  }

  // ── Detail-view actions ────────────────────────────────────────
  let addMemberHandle = $state("");
  let addingMember = $state(false);
  let detailErr = $state<string | null>(null);

  async function addMember() {
    if (!openGroup) return;
    const h = addMemberHandle.trim().toLowerCase().replace(/^@/, "");
    if (!h) return;
    addingMember = true;
    detailErr = null;
    try {
      if (liveMode) {
        await addGroupMember(openGroup.id, h, "member");
        openGroup = await getGroup(openGroup.id);
      } else {
        openGroup = {
          ...openGroup,
          members: [
            ...openGroup.members,
            { handle: h, role: "member", joined_at: Date.now() },
          ],
        };
      }
      addMemberHandle = "";
    } catch (e) {
      detailErr = e instanceof Error ? e.message : String(e);
    } finally {
      addingMember = false;
    }
  }

  async function removeMember(handle: string) {
    if (!openGroup) return;
    const original = openGroup;
    openGroup = {
      ...openGroup,
      members: openGroup.members.filter((m) => m.handle !== handle),
    };
    try {
      if (liveMode) await removeGroupMember(original.id, handle);
    } catch (e) {
      openGroup = original;
      detailErr = e instanceof Error ? e.message : String(e);
    }
  }

  async function destroy() {
    if (!openGroup) return;
    if (!(await tauriConfirm(`Delete group "${openGroup.name}"? Members will lose access.`, { kind: "warning" }))) return;
    try {
      if (liveMode) await deleteGroup(openGroup.id);
      openGroup = null;
      await load();
    } catch (e) {
      detailErr = e instanceof Error ? e.message : String(e);
    }
  }

</script>

<div class="wrap">
  <header class="head">
    <div>
      <h2>Groups</h2>
      <p class="sub">
        {groups.length} {groups.length === 1 ? "group" : "groups"}
        {#if liveMode}
          <span class="mode-tag live">live</span>
        {:else}
          <span class="mode-tag offline">offline</span>
        {/if}
      </p>
    </div>
    <button type="button" class="btn primary" onclick={() => (creating = true)}>
      <Plus weight="bold" size={13} /> Create group
    </button>
  </header>

  {#if loadError}
    <div class="banner err">
      <div>
        <strong>Couldn't reach broker.</strong>
        <span class="banner-detail">{loadError}</span>
      </div>
      <button type="button" class="banner-retry" onclick={load}>Retry</button>
    </div>
  {/if}

  {#if groups.length === 0 && !loading}
    <EmptyState
      title="No groups yet"
      blurb={liveMode
        ? "Create one to share workbooks with a stable circle — friends, project team, anything. The Create group button above starts the flow."
        : "Engine isn't reachable. Once Workhorse is running and you're connected, your groups show up here."}
      glyph="◐"
      hue={270}
    />
  {:else}
    <div class="grid">
      {#each groups as g, i (g.id)}
        <button
          type="button"
          class="card"
          onclick={() => openDetail(g)}
          in:fly={{ y: 4, duration: 200, delay: i * 35, easing: cubicOut }}
        >
          <div class="card-head">
            {#if g.my_role === "owner"}
              <span class="role-tag owner"><Crown weight="fill" size={10} /> owner</span>
            {:else if g.my_role === "admin"}
              <span class="role-tag admin"><ShieldHalf weight="fill" size={10} /> admin</span>
            {/if}
            <span class="vis">{g.visibility}</span>
          </div>
          <h3 class="card-name">{g.name}</h3>
          <p class="card-meta">updated {relTime(g.updated_at)}</p>
        </button>
      {/each}
    </div>
  {/if}
</div>

<!-- ── Create modal ───────────────────────────────────────────── -->
{#if creating}
  <button type="button" class="overlay" transition:fade={{ duration: 140 }} onclick={() => (creating = false)} aria-label="Close"></button>
  <div class="modal" role="dialog" aria-modal="true" transition:fly={{ y: 10, duration: 220, easing: cubicOut }}>
    <header class="modal-head">
      <h2>New group</h2>
      <button type="button" class="x" onclick={() => (creating = false)} aria-label="Close">
        <X weight="bold" size={14} />
      </button>
    </header>
    <div class="modal-body">
      <label class="field">
        <span class="lbl">Name</span>
        <input type="text" bind:value={newName} placeholder="e.g. Tuesday drafts" maxlength={64} />
      </label>
      <div class="field">
        <span class="lbl">Visibility</span>
        <div class="seg-row">
          <label class="seg" class:active={newVisibility === "private"}>
            <input type="radio" bind:group={newVisibility} value="private" />
            Private
          </label>
          <label class="seg" class:active={newVisibility === "invite-only"}>
            <input type="radio" bind:group={newVisibility} value="invite-only" />
            Invite-only
          </label>
        </div>
      </div>
      {#if createErr}
        <p class="banner err">{createErr}</p>
      {/if}
    </div>
    <footer class="modal-foot">
      <button type="button" class="btn ghost" onclick={() => (creating = false)}>Cancel</button>
      <button type="button" class="btn primary" disabled={createSaving || !newName.trim()} onclick={submitCreate}>
        {createSaving ? "Creating…" : "Create"}
      </button>
    </footer>
  </div>
{/if}

<!-- ── Detail view ─────────────────────────────────────────────── -->
{#if openGroup}
  <button type="button" class="overlay" transition:fade={{ duration: 140 }} onclick={() => (openGroup = null)} aria-label="Close"></button>
  <div class="modal lg" role="dialog" aria-modal="true" transition:fly={{ y: 10, duration: 220, easing: cubicOut }}>
    <header class="modal-head">
      <button type="button" class="back" onclick={() => (openGroup = null)} aria-label="Back">
        <ChevronLeft weight="bold" size={15} />
      </button>
      <h2>{openGroup.name}</h2>
      <button type="button" class="x" onclick={() => (openGroup = null)} aria-label="Close">
        <X weight="bold" size={14} />
      </button>
    </header>
    <div class="modal-body">
      <div class="detail-meta">
        <span class="meta-row"><strong>{openGroup.members.length}</strong> {openGroup.members.length === 1 ? "member" : "members"}</span>
        <span class="meta-row">visibility: <strong>{openGroup.visibility}</strong></span>
        <span class="meta-row">owner: <strong>@{openGroup.owner_handle}</strong></span>
      </div>

      {#if openGroup.my_role === "owner" || openGroup.my_role === "admin"}
        <section class="add-member">
          <span class="lbl">Add member</span>
          <div class="add-row">
            <span class="at">@</span>
            <input type="text" bind:value={addMemberHandle} placeholder="handle" autocomplete="off" spellcheck={false} />
            <button type="button" class="btn primary sm" disabled={addingMember || !addMemberHandle.trim()} onclick={addMember}>
              <UserPlus weight="fill" size={12} /> Add
            </button>
          </div>
        </section>
      {/if}

      <section>
        <span class="lbl">Members</span>
        <div class="member-list">
          {#each openGroup.members as m (m.handle)}
            <div class="member">
              <Avatar handle={m.handle} size="xs" />
              <HandleChip handle={m.handle} variant="inline" />
              {#if m.role === "owner"}
                <span class="role-tag owner sm"><Crown weight="fill" size={9} /> owner</span>
              {:else if m.role === "admin"}
                <span class="role-tag admin sm"><ShieldHalf weight="fill" size={9} /> admin</span>
              {/if}
              <span class="spacer"></span>
              {#if m.role !== "owner" && (openGroup.my_role === "owner" || openGroup.my_role === "admin")}
                <button type="button" class="kebab" onclick={() => removeMember(m.handle)} aria-label="Remove">
                  <X weight="bold" size={11} />
                </button>
              {/if}
            </div>
          {/each}
        </div>
      </section>

      {#if detailErr}
        <p class="banner err">{detailErr}</p>
      {/if}
    </div>
    {#if openGroup.my_role === "owner"}
      <footer class="modal-foot">
        <button type="button" class="btn ghost danger" onclick={destroy}>
          <Trash2 weight="fill" size={12} /> Delete group
        </button>
      </footer>
    {/if}
  </div>
{/if}

<style>
  .wrap {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    max-width: 760px;
    margin: 0 auto;
  }
  .head { display: flex; align-items: flex-end; justify-content: space-between; gap: 0.5rem; }
  .head h2 { margin: 0 0 .15rem; font-size: 1rem; font-weight: 600; letter-spacing: -.01em; }
  .head .sub { margin: 0; color: var(--color-fg-muted); font-size: 0.82rem; display: inline-flex; align-items: center; gap: 6px; }
  .mode-tag {
    padding: 1px 6px;
    border-radius: 999px;
    font-size: 0.66rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    border: 1px solid transparent;
  }
  .mode-tag.offline {
    background: rgba(160, 100, 200, 0.10);
    border-color: rgba(160, 100, 200, 0.30);
    color: rgb(110, 70, 160);
  }
  .mode-tag.live {
    background: rgba(34, 160, 105, 0.10);
    border-color: rgba(34, 160, 105, 0.30);
    color: rgb(20, 110, 70);
  }
  .banner {
    margin: 0;
    padding: 7px 12px;
    border-radius: 6px;
    font-size: 0.78rem;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: 10px;
    justify-content: space-between;
  }
  .banner.err {
    color: rgb(180, 50, 50);
    background: rgba(220, 60, 60, 0.08);
    border: 1px solid rgba(220, 60, 60, 0.22);
  }
  .banner-detail {
    color: rgb(140, 70, 70);
    font-weight: 400;
    margin-left: 8px;
  }
  .banner-retry {
    padding: 4px 10px;
    border-radius: 5px;
    border: 1px solid rgba(220, 60, 60, 0.30);
    background: white;
    color: rgb(180, 50, 50);
    font-size: 0.74rem;
    font-weight: 600;
    cursor: pointer;
    flex-shrink: 0;
  }
  .banner-retry:hover { background: rgba(220, 60, 60, 0.08); }

  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 0.6rem;
  }
  .card {
    display: flex; flex-direction: column; gap: 0.3rem;
    padding: 0.85rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    text-align: left;
    cursor: pointer;
    color: var(--color-fg);
    transition: transform 200ms cubic-bezier(0.22, 1.2, 0.36, 1), border-color 200ms ease, box-shadow 200ms ease;
  }
  .card:hover {
    transform: translateY(-2px);
    border-color: var(--color-border-strong);
    box-shadow: 0 6px 16px rgba(15, 15, 15, 0.05);
  }
  .card-head { display: flex; align-items: center; justify-content: space-between; gap: 6px; min-height: 16px; }
  .card-name { margin: 0; font-size: 0.94rem; font-weight: 600; letter-spacing: -0.01em; }
  .card-meta { margin: 0; color: var(--color-fg-muted); font-size: 0.74rem; }
  .vis {
    font-size: 0.68rem;
    color: var(--color-fg-subtle);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    font-weight: 600;
  }

  .role-tag {
    display: inline-flex; align-items: center; gap: 3px;
    padding: 2px 6px;
    border-radius: 999px;
    font-size: 0.66rem;
    font-weight: 600;
    text-transform: lowercase;
    letter-spacing: 0.02em;
  }
  .role-tag.sm { font-size: 0.62rem; padding: 1px 5px; }
  .role-tag.owner {
    color: rgb(150, 95, 10);
    background: rgba(225, 145, 30, 0.10);
    border: 1px solid rgba(225, 145, 30, 0.28);
  }
  .role-tag.admin {
    color: rgb(75, 110, 175);
    background: rgba(90, 130, 200, 0.10);
    border: 1px solid rgba(90, 130, 200, 0.28);
  }

  /* Modal */
  .overlay {
    position: fixed; inset: 0; z-index: 100;
    background: rgba(15, 15, 15, 0.42);
    backdrop-filter: blur(2px);
    border: 0; padding: 0;
  }
  .modal {
    position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%);
    width: min(440px, 92vw); max-height: 92vh;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 16px;
    box-shadow: 0 30px 80px rgba(15, 15, 15, 0.28);
    z-index: 101;
    display: flex; flex-direction: column;
    overflow: hidden;
  }
  .modal.lg { width: min(520px, 92vw); }
  .modal-head {
    display: flex; align-items: center; gap: 8px;
    padding: 0.7rem 0.85rem;
    border-bottom: 1px solid var(--color-border);
  }
  .modal-head h2 { margin: 0; font-size: 0.95rem; font-weight: 600; flex: 1; }
  .x, .back {
    display: inline-flex; align-items: center; justify-content: center;
    width: 26px; height: 26px;
    border-radius: 6px;
    background: transparent; border: 0;
    color: var(--color-fg-muted); cursor: pointer;
  }
  .x:hover, .back:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .modal-body {
    padding: 0.95rem 1rem;
    display: flex; flex-direction: column; gap: 0.85rem;
    overflow-y: auto;
  }
  .field { display: flex; flex-direction: column; gap: 6px; }
  .lbl {
    font-size: 0.72rem;
    font-weight: 600;
    color: var(--color-fg-muted);
    letter-spacing: -0.005em;
  }
  .field input[type="text"] {
    width: 100%;
    padding: 9px 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border-strong);
    border-radius: 8px;
    font: inherit;
    font-size: 0.88rem;
    color: var(--color-fg);
  }
  .field input[type="text"]:focus {
    outline: none;
    border-color: var(--color-fg);
    background: var(--color-surface);
    box-shadow: 0 0 0 3px var(--color-ring);
  }

  .seg-row {
    display: inline-flex; align-items: center; gap: 4px;
    padding: 3px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    align-self: flex-start;
  }
  .seg {
    display: inline-flex; align-items: center;
    padding: 6px 12px;
    border-radius: 999px;
    font-size: 0.78rem;
    font-weight: 500;
    color: var(--color-fg-muted);
    cursor: pointer;
  }
  .seg input { position: absolute; opacity: 0; pointer-events: none; }
  .seg.active {
    background: var(--color-surface);
    color: var(--color-fg);
    box-shadow: inset 0 0 0 1px var(--color-border-strong);
  }

  .add-member { display: flex; flex-direction: column; gap: 6px; }
  .add-row {
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: center;
    gap: 8px;
    padding: 7px 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border-strong);
    border-radius: 10px;
  }
  .add-row .at { color: var(--color-fg-muted); font-size: 0.95rem; }
  .add-row input { background: transparent; border: 0; outline: none; font: inherit; font-size: 0.86rem; }

  .detail-meta {
    display: flex; flex-direction: column; gap: 4px;
    padding: 0.7rem;
    background: var(--color-surface-soft);
    border-radius: 9px;
  }
  .meta-row { font-size: 0.78rem; color: var(--color-fg-muted); }

  .member-list { display: flex; flex-direction: column; gap: 3px; }
  .member {
    display: flex; align-items: center; gap: 8px;
    padding: 5px 6px;
    border-radius: 7px;
  }
  .member:hover { background: var(--color-surface-soft); }
  .spacer { flex: 1; }
  .kebab {
    display: inline-flex; align-items: center; justify-content: center;
    width: 22px; height: 22px; border-radius: 5px;
    background: transparent; border: 0;
    color: var(--color-fg-muted); cursor: pointer;
  }
  .kebab:hover { background: rgba(15, 15, 15, 0.08); color: var(--color-fg); }

  .modal-foot {
    display: flex; justify-content: flex-end; gap: 6px;
    padding: 0.7rem 0.85rem;
    border-top: 1px solid var(--color-border);
  }

  .btn {
    display: inline-flex; align-items: center; gap: 5px;
    height: 30px; padding: 0 12px;
    border-radius: 8px;
    font: inherit; font-size: 0.8rem; font-weight: 500;
    cursor: pointer;
    transition: transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1);
  }
  .btn.sm { height: 26px; padding: 0 10px; font-size: 0.76rem; }
  .btn:hover:not(:disabled) { transform: translateY(-1px); }
  .btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .btn.primary { background: var(--color-fg); color: var(--color-page); border: 1px solid var(--color-fg); }
  .btn.ghost { background: transparent; color: var(--color-fg); border: 1px solid var(--color-border-strong); }
  .btn.ghost:hover { background: var(--color-surface-soft); }
  .btn.ghost.danger { color: rgb(180, 50, 50); }
  .btn.ghost.danger:hover { background: rgba(220, 60, 60, 0.08); }
</style>
