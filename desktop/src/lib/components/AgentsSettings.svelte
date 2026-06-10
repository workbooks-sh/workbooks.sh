<script lang="ts">
  /**
   * AgentsSettings — single row list of agents. No giant "Default
   * agent" / "Default LLM" cards taking up half the page. Default IS
   * just a property on an agent row (pin star) and the LLM fallback
   * is a small inline picker at the top.
   *
   * Mirrors the Studio archive pattern (archive/studio/frontend/src/
   * lib/components/chat/AgentPicker.svelte): tight rows, icon + title
   * + tagline + actions, dashed "+ Create new agent" at the bottom.
   */
  import { onMount } from "svelte";
  import { Plus, WarningCircle as AlertCircle, Star, Robot as Bot, DotsThree as MoreHorizontal, Trash as Trash2, PencilSimple as Pencil } from "phosphor-svelte";
  import { agents, type AgentCatalogEntry } from "$lib/bridge/agents.svelte";
  import { agentSettings } from "$lib/bridge/agent_settings.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import ModelPicker from "$lib/chat/ModelPicker.svelte";
  import AgentIcon from "$lib/chat/AgentIcon.svelte";
  import AgentEditor from "$lib/chat/AgentEditor.svelte";
  import ContextMenu from "$lib/components/ContextMenu.svelte";
  import PaletteModal from "$lib/palette/PaletteModal.svelte";
  import { packageStore as workspace } from "$lib/bridge/package.svelte";

  /** undefined = closed, string slug = edit-existing. Create-new
   *  no longer routes through this slot — it opens the create-agent
   *  wizard instead (wb-ne0o / wb-donh). */
  let editorSlug = $state<string | undefined>(undefined);

  // wb-dj5r — new-agent wizard runs inside the palette modal.
  let paletteOpen = $state(false);
  let paletteWizardMode = $state<{ id: string; title: string } | null>(null);

  let menuOpen = $state(false);
  let menuX = $state(0);
  let menuY = $state(0);
  let menuTarget = $state<AgentCatalogEntry | null>(null);

  onMount(async () => {
    await Promise.all([agents.init(), agentSettings.init()]);
  });

  $effect(() => {
    if (sidecar.status.state === "ready") {
      void agents.refresh();
    }
  });

  // Sort: pinned default first, then alphabetical by title.
  const rows = $derived<AgentCatalogEntry[]>(
    [...agents.agents].sort((a, b) => {
      const pinned = agentSettings.settings.default_agent_slug;
      if (a.slug === pinned && b.slug !== pinned) return -1;
      if (b.slug === pinned && a.slug !== pinned) return 1;
      return (a.title ?? a.slug).localeCompare(b.title ?? b.slug);
    }),
  );

  function openMenu(e: MouseEvent, a: AgentCatalogEntry) {
    e.stopPropagation();
    menuTarget = a;
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    menuX = r.right - 180;
    menuY = r.bottom + 4;
    menuOpen = true;
  }

  async function togglePin(a: AgentCatalogEntry) {
    menuOpen = false;
    const pinned = agentSettings.settings.default_agent_slug;
    await agentSettings.setDefaultAgent(pinned === a.slug ? "" : a.slug);
  }

  function openEdit(a: AgentCatalogEntry) {
    menuOpen = false;
    editorSlug = a.slug;
  }

  function openCreate() {
    // Agent creation runs through the wizard, hosted inside the
    // palette modal (wb-dj5r). The editor stays for editing existing
    // agents; new-agent flow is fully wizard-driven so the user
    // describes intent + the agent scaffolds the org file.
    paletteWizardMode = { id: "create-agent", title: "Create an agent" };
    paletteOpen = true;
  }

  function closePalette() {
    paletteOpen = false;
    paletteWizardMode = null;
  }

  function closeEditor() {
    editorSlug = undefined;
  }

  async function onWizardFinish(_briefPath: string) {
    // The follow-on workhorse session writes the actual agent .org.
    // Refresh the catalog so the new row shows up immediately.
    await agents.refresh().catch(() => {});
  }

  // Default LLM (fallback model) — inline at the top.
  const defaultLLM = $derived(agentSettings.settings.default_model);
  async function onDefaultLLMChange(v: string) {
    if (!v || v === defaultLLM) return;
    try {
      await agentSettings.setModel(v);
    } catch (e) {
      // Errors surface inline via the global error state; the
      // picker resets its bound value on next refresh.
      console.warn("[agents-settings] setModel:", e);
    }
  }
</script>

<header class="head">
  <h2>Agents</h2>
  <span class="count">{agents.agents.length}</span>
  <span class="spacer"></span>
  <button type="button" class="primary" onclick={openCreate}>
    <Plus weight="bold" size={12} aria-hidden="true" />
    New agent
  </button>
</header>

<div class="default-llm">
  <span class="lbl">Default LLM</span>
  <ModelPicker value={defaultLLM} onchange={onDefaultLLMChange} placeholder="Falls back to env" />
  <span class="hint">Agents without a pinned model fall back here.</span>
</div>

{#if agents.loading && agents.agents.length === 0}
  <div class="state">Loading catalog…</div>
{:else if agents.lastError && agents.agents.length === 0}
  <div class="state err">
    <AlertCircle weight="fill" size={12} />
    {agents.lastError}
  </div>
{:else if agents.agents.length === 0}
  <div class="state">
    <Bot weight="fill" size={14} />
    No agents yet. Workhorse and any user-scope agents will appear here.
  </div>
{:else}
  <ul class="list">
    {#each rows as a (a.slug)}
      {@const isPinned = a.slug === agentSettings.settings.default_agent_slug}
      <li class="row-wrap">
        <button type="button" class="row" onclick={() => openEdit(a)}>
          <span class="row-icon">
            <AgentIcon icon={a.icon} title={a.title} slug={a.slug} size={22} />
          </span>
          <span class="row-body">
            <span class="row-title">
              {a.title ?? a.slug}
              {#if isPinned}<span class="pin-chip">default</span>{/if}
              {#if a.parse_error}<span class="err-chip">parse error</span>{/if}
            </span>
            <span class="row-meta">
              {#if a.tagline}
                {a.tagline}
              {:else if a.model}
                <code>{a.model}</code>
              {:else}
                <em>uses default LLM</em>
              {/if}
            </span>
          </span>
        </button>
        <button
          type="button"
          class="icon-btn"
          class:active={isPinned}
          title={isPinned ? "Unpin as default" : "Pin as default"}
          aria-label={isPinned ? "Unpin as default" : "Pin as default"}
          onclick={() => togglePin(a)}
        >
          <Star weight="fill"
            size={13}
            fill={isPinned ? "currentColor" : "none"}
            aria-hidden="true"
          />
        </button>
        <button
          type="button"
          class="icon-btn"
          title="More"
          aria-label="More"
          onclick={(e) => openMenu(e, a)}
        >
          <MoreHorizontal weight="bold" size={13} aria-hidden="true" />
        </button>
      </li>
    {/each}
    <li>
      <button type="button" class="row create" onclick={openCreate}>
        <span class="row-icon dashed">
          <Plus weight="bold" size={12} aria-hidden="true" />
        </span>
        <span class="row-body">
          <span class="row-title">Create new agent</span>
          <span class="row-meta">Opens the editor</span>
        </span>
      </button>
    </li>
  </ul>
{/if}

<ContextMenu bind:open={menuOpen} x={menuX} y={menuY}>
  {#snippet children()}
    {#if menuTarget}
      <button class="ctx-item" onclick={() => openEdit(menuTarget!)}>
        <Pencil weight="fill" size={12} aria-hidden="true" />
        <span>Edit</span>
      </button>
      <button class="ctx-item" onclick={() => togglePin(menuTarget!)}>
        <Star weight="fill" size={12} aria-hidden="true" />
        <span>
          {menuTarget.slug === agentSettings.settings.default_agent_slug
            ? "Unpin as default"
            : "Pin as default"}
        </span>
      </button>
    {/if}
  {/snippet}
</ContextMenu>

{#if editorSlug !== undefined}
  <AgentEditor
    slug={editorSlug}
    oncancel={closeEditor}
    onsaved={() => closeEditor()}
  />
{/if}

<PaletteModal
  open={paletteOpen}
  workdir={workspace.active?.folders?.[0] ?? null}
  wizardMode={paletteWizardMode}
  onclose={closePalette}
  onwizardfinish={onWizardFinish}
/>

<style>
  .head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin-bottom: 1.25rem;
  }
  h2 {
    margin: 0;
    font-size: 16px;
    font-weight: 600;
    color: var(--color-fg);
  }
  .count {
    font-size: 11px;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    padding: 0.05em 0.5em;
    border-radius: 999px;
  }
  .spacer {
    flex: 1;
  }
  .primary {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.35rem 0.7rem;
    background: var(--color-fg);
    color: var(--color-page);
    border: 0;
    border-radius: 5px;
    font: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
  }

  .default-llm {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.55rem 0.7rem;
    margin-bottom: 0.9rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    flex-wrap: wrap;
  }
  .default-llm .lbl {
    font-size: 12.5px;
    font-weight: 600;
    color: var(--color-fg);
  }
  .default-llm .hint {
    font-size: 11.5px;
    color: var(--color-fg-muted);
  }

  .state {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.9rem 0.7rem;
    color: var(--color-fg-muted);
    font-size: 13px;
  }
  .state.err {
    color: #fca5a5;
  }

  .list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }
  .row-wrap {
    display: flex;
    align-items: center;
    gap: 0.25rem;
    padding: 0 0.25rem 0 0;
    border: 1px solid transparent;
    border-radius: 6px;
  }
  .row-wrap:hover {
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    flex: 1;
    min-width: 0;
    padding: 0.5rem 0.7rem;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    text-align: left;
    cursor: pointer;
    border-radius: 6px;
  }
  .row-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    flex-shrink: 0;
    background: var(--color-surface);
    border-radius: 6px;
    border: 1px solid var(--color-border);
  }
  .row-icon.dashed {
    background: transparent;
    border-style: dashed;
    color: var(--color-fg-muted);
  }
  .row-body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.05rem;
  }
  .row-title {
    font-size: 13.5px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 0.4rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-meta {
    font-size: 11.5px;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-meta em {
    font-style: italic;
  }
  .row-meta code {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: inherit;
  }
  .pin-chip,
  .err-chip {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 0.1em 0.45em;
    border-radius: 3px;
    font-weight: 600;
  }
  .pin-chip {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .err-chip {
    background: rgba(252, 165, 165, 0.18);
    color: #fca5a5;
  }
  .icon-btn {
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    padding: 0.3rem;
    border-radius: 4px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .icon-btn:hover {
    background: var(--color-border);
    color: var(--color-fg);
  }
  .icon-btn.active {
    color: var(--color-fg);
  }
  .row.create {
    color: var(--color-fg-muted);
  }
  .row.create:hover {
    color: var(--color-fg);
  }
  :global(.ctx-item) {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    width: 100%;
    padding: 0.4rem 0.7rem;
    background: transparent;
    border: 0;
    text-align: left;
    cursor: pointer;
    color: var(--color-fg);
    font: inherit;
    font-size: 13px;
  }
  :global(.ctx-item:hover) {
    background: var(--color-surface-soft);
  }
</style>
