<script lang="ts">
  /**
   * wb-8285 — SkillPicker dropdown for the chat compose.
   *
   * Matches AgentPickerDropdown's chrome — 28px trigger, 22px row
   * icons, dashed "+ New skill" entry at the bottom that opens the
   * create-skill wizard. Distinct from the SkillsSettings list (which
   * manages integration-skills like Composio).
   */
  import { ChevronDown, Plus, Wand2 } from "@lucide/svelte";
  import { tick } from "svelte";
  import { skillCatalog, type SkillMdEntry } from "$lib/bridge/skill_catalog.svelte";

  let {
    attached,
    onattach,
    oncreate,
  }: {
    attached: string[];
    onattach: (slug: string) => void;
    oncreate?: () => void;
  } = $props();

  let triggerEl = $state<HTMLButtonElement | null>(null);
  let menuEl = $state<HTMLDivElement | null>(null);
  let open = $state(false);
  let highlight = $state(0);

  const rows = $derived<SkillMdEntry[]>(
    [...skillCatalog.entries]
      .filter((s) => !attached.includes(s.slug))
      .sort((a, b) => a.slug.localeCompare(b.slug)),
  );

  async function toggle(e: MouseEvent) {
    e.stopPropagation();
    open = !open;
    if (open) {
      await skillCatalog.ensureLoaded();
      highlight = 0;
      await tick();
    }
  }

  function pick(s: SkillMdEntry) {
    onattach(s.slug);
    open = false;
  }

  function pickCreate() {
    open = false;
    oncreate?.();
  }

  $effect(() => {
    if (!open) return;
    function away(e: MouseEvent) {
      const t = e.target as Node;
      if (menuEl?.contains(t) || triggerEl?.contains(t)) return;
      open = false;
    }
    function key(e: KeyboardEvent) {
      if (!open) return;
      if (e.key === "Escape") {
        open = false;
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        highlight = Math.min(highlight + 1, rows.length);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        highlight = Math.max(highlight - 1, 0);
      } else if (e.key === "Enter") {
        e.preventDefault();
        if (highlight < rows.length) pick(rows[highlight]);
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

<div class="picker">
  <button
    type="button"
    bind:this={triggerEl}
    class="trigger"
    onclick={toggle}
    aria-haspopup="listbox"
    aria-expanded={open}
    title="Attach a skill"
  >
    <Plus size={11} strokeWidth={2.25} />
    <span>Skill</span>
    <ChevronDown size={11} strokeWidth={2} aria-hidden="true" />
  </button>

  {#if open}
    <div
      bind:this={menuEl}
      class="menu"
      role="listbox"
      onclick={(e) => e.stopPropagation()}
    >
      {#if skillCatalog.loading && rows.length === 0}
        <div class="empty">Loading…</div>
      {:else if rows.length === 0}
        <div class="empty">
          {attached.length > 0 ? "All skills attached." : "No skills available."}
        </div>
      {:else}
        {#each rows as s, i (s.slug)}
          <button
            type="button"
            role="option"
            class="row"
            class:active={i === highlight}
            onclick={() => pick(s)}
            onmouseenter={() => (highlight = i)}
          >
            <span class="row-icon" aria-hidden="true">
              <Wand2 size={14} strokeWidth={1.7} />
            </span>
            <span class="row-body">
              <span class="row-title">{s.name}</span>
              {#if s.description}
                <span class="row-tag">{s.description}</span>
              {/if}
            </span>
            <span class="src-chip">{s.source}</span>
          </button>
        {/each}
      {/if}
      {#if oncreate}
        <div class="add-row">
          <button
            type="button"
            class="row add"
            class:active={highlight === rows.length}
            onclick={pickCreate}
            onmouseenter={() => (highlight = rows.length)}
          >
            <span class="row-icon dashed" aria-hidden="true">
              <Plus size={12} strokeWidth={2} />
            </span>
            <span class="add-label">Create skill</span>
          </button>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .picker {
    position: relative;
    display: inline-block;
  }
  .trigger {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 24px;
    padding: 0 0.45rem;
    background: var(--color-surface);
    border: 1px dashed var(--color-border-strong);
    border-radius: 999px;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 11.5px;
    cursor: pointer;
  }
  .trigger:hover {
    color: var(--color-fg);
    border-style: solid;
  }
  .menu {
    position: absolute;
    bottom: calc(100% + 6px);
    left: 0;
    width: 320px;
    max-height: 50vh;
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
  .row {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    width: 100%;
    text-align: left;
    padding: 0.4rem 0.5rem;
    border: 0;
    background: transparent;
    border-radius: 5px;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
  }
  .row:hover,
  .row.active {
    background: var(--color-surface-soft);
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
    color: var(--color-fg-muted);
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
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
  }
  .src-chip {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border-radius: 3px;
    padding: 0.05em 0.4em;
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
</style>
