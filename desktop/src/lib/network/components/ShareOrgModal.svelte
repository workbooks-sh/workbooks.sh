<script lang="ts">
  /**
   * ShareOrgModal — share a resource (workbook / app) with members of the
   * current organization.
   *
   *   1. loads org members (real photo avatars) + any prior shares
   *   2. pick members — click a face to add/remove; selected fan into a
   *      live stacked-avatar preview at the top
   *   3. assign a role per recipient (Viewer / Editor / Owner)
   *   4. optional note → Share
   *   5. on success the modal reflects the shared state (selected rows
   *      stamped "Shared", stacked preview persists)
   *
   * Wired to the Host `org_*` capabilities via $lib/bridge/org. In the
   * browser preview those resolve against the webHost mock providers.
   */
  import {
    MagnifyingGlass,
    Check,
    CircleNotch as Loader,
    UsersThree,
    X,
  } from "phosphor-svelte";
  import Avatar from "./Avatar.svelte";
  import StackedAvatars from "./StackedAvatars.svelte";
  import {
    getOrg,
    listMembers,
    sharesFor,
    share as shareApi,
    unshare as unshareApi,
    type OrgMember,
    type OrgInfo,
    type ShareRecipient,
  } from "$lib/bridge/org.svelte";

  let {
    resourceId,
    resourceTitle = "this workbook",
    onclose,
    onshared,
  }: {
    resourceId: string;
    resourceTitle?: string;
    onclose: () => void;
    /** Fired after a successful share with the full recipient list, so
     *  the trigger can refresh its stacked avatars. */
    onshared?: (recipients: ShareRecipient[]) => void;
  } = $props();

  let cardEl = $state<HTMLDivElement>();
  let loading = $state(true);
  let loadError = $state<string | null>(null);
  let org = $state<OrgInfo | null>(null);
  let members = $state<OrgMember[]>([]);

  // handle → role for the current selection (includes already-shared).
  let selected = $state<Record<string, string>>({});
  // handles that were already shared when the modal opened (stamped "Shared").
  let already = $state<Set<string>>(new Set());

  let query = $state("");
  let note = $state("");
  let sharing = $state(false);
  let done = $state(false);

  const defaultRole = $derived(org?.roles?.[0] ?? "Viewer");

  const filtered = $derived(
    members.filter((m) => {
      const q = query.trim().toLowerCase();
      if (!q) return true;
      return (
        m.display_name.toLowerCase().includes(q) ||
        m.handle.toLowerCase().includes(q) ||
        m.title.toLowerCase().includes(q)
      );
    }),
  );

  const selectedMembers = $derived(
    members.filter((m) => m.handle in selected),
  );
  const newCount = $derived(
    selectedMembers.filter((m) => !already.has(m.handle)).length,
  );

  function isSelected(h: string): boolean {
    return h in selected;
  }

  function toggle(m: OrgMember) {
    if (m.handle in selected) {
      const next = { ...selected };
      delete next[m.handle];
      selected = next;
    } else {
      selected = { ...selected, [m.handle]: defaultRole };
    }
  }

  function setRole(handle: string, role: string) {
    selected = { ...selected, [handle]: role };
  }

  async function removeShared(m: OrgMember) {
    // Pull an already-shared member off the resource immediately.
    try {
      await unshareApi(resourceId, m.handle);
    } catch (e) {
      loadError = e instanceof Error ? e.message : String(e);
      return;
    }
    already.delete(m.handle);
    already = new Set(already);
    const next = { ...selected };
    delete next[m.handle];
    selected = next;
  }

  async function doShare() {
    if (newCount === 0 || sharing) return;
    sharing = true;
    loadError = null;
    try {
      const recipients = Object.entries(selected).map(([handle, role]) => ({
        handle,
        role,
      }));
      const result = await shareApi(resourceId, recipients);
      already = new Set(result.map((r) => r.handle));
      done = true;
      onshared?.(result);
      // brief confirmation, then close
      setTimeout(() => onclose(), 850);
    } catch (e) {
      loadError = e instanceof Error ? e.message : String(e);
    } finally {
      sharing = false;
    }
  }

  function backdrop(e: MouseEvent) {
    if (cardEl && cardEl.contains(e.target as Node)) return;
    if (!sharing) onclose();
  }
  function key(e: KeyboardEvent) {
    if (e.key === "Escape" && !sharing) onclose();
  }

  let bootstrapped = false;
  $effect(() => {
    if (bootstrapped) return;
    bootstrapped = true;
    void (async () => {
      try {
        const [o, ms, existing] = await Promise.all([
          getOrg(),
          listMembers(),
          sharesFor(resourceId),
        ]);
        org = o;
        members = ms;
        const sel: Record<string, string> = {};
        const have = new Set<string>();
        for (const r of existing) {
          sel[r.handle] = r.role;
          have.add(r.handle);
        }
        selected = sel;
        already = have;
      } catch (e) {
        loadError = e instanceof Error ? e.message : String(e);
      } finally {
        loading = false;
      }
    })();
  });
</script>

<svelte:window onkeydown={key} />

<div class="backdrop" onmousedown={backdrop} role="presentation">
  <div class="card" bind:this={cardEl}>
    <header class="head">
      <div class="icon" aria-hidden="true"><UsersThree weight="fill" size={20} /></div>
      <div class="head-text">
        <h3>Share with {org?.name ?? "your organization"}</h3>
        <p class="sub">Pick members to share <strong>{resourceTitle}</strong> with.</p>
      </div>
      <button class="x" type="button" onclick={onclose} aria-label="Close"><X weight="bold" size={15} /></button>
    </header>

    {#if loading}
      <div class="state"><Loader weight="bold" size={16} class="spin" /> Loading members…</div>
    {:else if loadError && members.length === 0}
      <div class="state error">{loadError}</div>
    {:else}
      <!-- Selected preview — live stacked avatars of who'll be shared with. -->
      <div class="preview" class:filled={selectedMembers.length > 0}>
        <StackedAvatars members={selectedMembers} size="md" max={7} />
        <span class="preview-label">
          {#if selectedMembers.length === 0}
            No one selected yet
          {:else}
            {selectedMembers.length} selected{#if already.size > 0} · {already.size} already shared{/if}
          {/if}
        </span>
      </div>

      <div class="search">
        <MagnifyingGlass weight="bold" size={14} />
        <input placeholder="Search members…" bind:value={query} />
      </div>

      <ul class="members">
        {#each filtered as m (m.handle)}
          {@const on = isSelected(m.handle)}
          {@const shared = already.has(m.handle)}
          <li class="member" class:on>
            <button class="pick" type="button" onclick={() => toggle(m)} aria-pressed={on}>
              <Avatar handle={m.handle} avatar={m.avatar} size="sm" ring={on} />
              <span class="who">
                <span class="name">{m.display_name}</span>
                <span class="title">{m.title}</span>
              </span>
              {#if on}<span class="tick"><Check weight="bold" size={12} /></span>{/if}
            </button>

            {#if on}
              <select
                class="role"
                value={selected[m.handle]}
                onchange={(e) => setRole(m.handle, (e.currentTarget as HTMLSelectElement).value)}
              >
                {#each org?.roles ?? [] as r}
                  <option value={r}>{r}</option>
                {/each}
              </select>
              {#if shared}
                <button class="unshare" type="button" title="Remove access" onclick={() => removeShared(m)}>
                  <X weight="bold" size={11} />
                </button>
              {/if}
            {/if}
          </li>
        {/each}
      </ul>

      <label class="note">
        <span>Add a note (optional)</span>
        <input placeholder="Take a look when you get a chance…" bind:value={note} />
      </label>
    {/if}

    <footer class="foot">
      <button class="btn ghost" type="button" onclick={onclose} disabled={sharing}>Cancel</button>
      <button
        class="btn primary"
        class:done
        type="button"
        onclick={doShare}
        disabled={loading || sharing || newCount === 0}
      >
        {#if done}
          <Check weight="bold" size={13} /> Shared
        {:else if sharing}
          <Loader weight="bold" size={13} class="spin" /> Sharing…
        {:else if newCount > 0}
          Share with {newCount}
        {:else}
          Share
        {/if}
      </button>
    </footer>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.38);
    backdrop-filter: blur(2px);
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }
  .card {
    width: 100%;
    max-width: 440px;
    max-height: 84vh;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 14px;
    box-shadow: var(--shadow-pop);
    padding: 1.1rem 1.1rem 0.9rem;
    display: flex;
    flex-direction: column;
    min-height: 0;
  }
  .head {
    display: flex;
    gap: 0.7rem;
    align-items: flex-start;
    margin-bottom: 0.9rem;
  }
  .icon {
    width: 34px;
    height: 34px;
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 10px;
    background: color-mix(in srgb, #3fe081 16%, transparent);
    color: #3fe081;
  }
  .head-text { flex: 1 1 auto; min-width: 0; }
  h3 { margin: 0 0 0.15rem; font-size: 0.96rem; font-weight: 600; letter-spacing: -0.01em; }
  .sub { margin: 0; color: var(--color-fg-muted); font-size: 0.78rem; line-height: 1.4; }
  .sub strong { color: var(--color-fg); font-weight: 600; }
  .x {
    flex-shrink: 0;
    width: 26px; height: 26px;
    display: inline-flex; align-items: center; justify-content: center;
    border: 0; border-radius: 7px; background: transparent;
    color: var(--color-fg-subtle); cursor: pointer;
  }
  .x:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .preview {
    display: flex; align-items: center; gap: 0.7rem;
    padding: 0.6rem 0.7rem;
    border: 1px dashed var(--color-border);
    border-radius: 10px;
    margin-bottom: 0.7rem;
    min-height: 48px;
    transition: border-color 0.15s, background 0.15s;
  }
  .preview.filled {
    border-style: solid;
    border-color: color-mix(in srgb, #3fe081 35%, var(--color-border));
    background: color-mix(in srgb, #3fe081 6%, transparent);
  }
  .preview-label { font-size: 0.76rem; color: var(--color-fg-muted); }

  .search {
    display: flex; align-items: center; gap: 0.45rem;
    padding: 0 0.65rem;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    color: var(--color-fg-subtle);
    margin-bottom: 0.5rem;
  }
  .search input {
    flex: 1 1 auto; border: 0; background: transparent;
    font: inherit; font-size: 0.84rem; color: var(--color-fg);
    padding: 0.5rem 0; outline: none;
  }

  .members {
    list-style: none; margin: 0 0 0.7rem; padding: 0;
    overflow-y: auto;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    min-height: 0;
  }
  .member {
    display: flex; align-items: center; gap: 0.4rem;
    padding: 0.32rem 0.5rem;
    border-bottom: 1px solid var(--color-border);
  }
  .member:last-child { border-bottom: none; }
  .member.on { background: color-mix(in srgb, #3fe081 7%, transparent); }
  .pick {
    flex: 1 1 auto; min-width: 0;
    display: flex; align-items: center; gap: 0.55rem;
    border: 0; background: transparent; font: inherit;
    padding: 0.25rem; border-radius: 8px; cursor: pointer; color: inherit;
    text-align: left;
  }
  .pick:hover { background: var(--color-surface-soft); }
  .who { display: flex; flex-direction: column; min-width: 0; }
  .name { font-size: 0.85rem; color: var(--color-fg); font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .title { font-size: 0.7rem; color: var(--color-fg-subtle); }
  .tick {
    margin-left: auto; flex-shrink: 0;
    width: 18px; height: 18px; border-radius: 50%;
    display: inline-flex; align-items: center; justify-content: center;
    background: #3fe081; color: #06281a;
  }
  .role {
    flex-shrink: 0;
    font: inherit; font-size: 0.72rem;
    padding: 0.2rem 0.35rem;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    background: var(--color-surface);
    color: var(--color-fg-muted);
    cursor: pointer;
  }
  .unshare {
    flex-shrink: 0;
    width: 22px; height: 22px; border-radius: 6px;
    display: inline-flex; align-items: center; justify-content: center;
    border: 1px solid var(--color-border); background: transparent;
    color: var(--color-fg-subtle); cursor: pointer;
  }
  .unshare:hover { color: #ef4444; border-color: color-mix(in srgb, #ef4444 40%, var(--color-border)); }

  .note { display: flex; flex-direction: column; gap: 0.3rem; margin-bottom: 0.2rem; }
  .note span { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--color-fg-subtle); }
  .note input {
    font: inherit; font-size: 0.82rem;
    padding: 0.5rem 0.65rem;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-page);
    color: var(--color-fg);
    outline: none;
  }
  .note input:focus { border-color: var(--color-border-strong); }

  .state {
    display: flex; align-items: center; gap: 0.5rem;
    padding: 1.4rem 0.8rem; justify-content: center;
    color: var(--color-fg-muted); font-size: 0.84rem;
  }
  .state.error { color: #ef4444; }

  .foot {
    display: flex; justify-content: flex-end; gap: 0.5rem;
    margin-top: 0.85rem; flex-shrink: 0;
  }
  .btn {
    display: inline-flex; align-items: center; gap: 0.35rem;
    height: 32px; padding: 0 0.95rem;
    border-radius: 8px; font-size: 0.83rem; font-weight: 500;
    font-family: inherit; cursor: pointer; border: 0;
    transition: opacity 0.12s, background 0.12s, transform 0.12s;
  }
  .btn:disabled { opacity: 0.45; cursor: default; }
  .btn.ghost {
    background: transparent; color: var(--color-fg-muted);
    border: 1px solid var(--color-border);
  }
  .btn.ghost:hover:not(:disabled) { background: var(--color-surface-soft); color: var(--color-fg); }
  .btn.primary { background: #3fe081; color: #06281a; }
  .btn.primary:hover:not(:disabled) { transform: translateY(-1px); }
  .btn.primary.done { background: #3fe081; }

  :global(.spin) { animation: spin 0.9s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
