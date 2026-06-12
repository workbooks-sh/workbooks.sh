<script lang="ts">
  /**
   * PackageGridView — iOS-springboard layout for the active Package
   * (wb-i38o.38). Renders one tile per workbook file that passes the
   * `<script id="workbook-spec">` marker scan (wb-i38o.37). Anything
   * that's not a workbook is hidden — for the full file view, the
   * panel header switcher flips to Tree mode.
   *
   * The "+ New workbook" tile is currently a stub — the creation flow
   * lands in a follow-up (the rail / chat / agent paths haven't been
   * decided yet). Clicking it surfaces a console hint for now.
   */
  import { onMount } from "svelte";
  import { Plus, FilePlus } from "phosphor-svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { packageStore, type WorkbookEntry } from "$lib/bridge/package.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { dnd } from "$lib/ui/dnd.svelte";
  import { fileIconUrl } from "$lib/ui/materialIcon";
  import PaletteModal from "$lib/palette/PaletteModal.svelte";

  let entries = $state<WorkbookEntry[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  async function load() {
    const active = packageStore.active;
    if (!active) {
      entries = [];
      loading = false;
      return;
    }
    loading = true;
    error = null;
    try {
      entries = await packageStore.workbooks(active.name);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      entries = [];
    } finally {
      loading = false;
    }
  }

  // Re-fetch whenever the active package changes (re-runs because we
  // read packageStore.active at the top of the effect).
  $effect(() => {
    void packageStore.active?.name;
    void load();
  });

  onMount(load);

  async function open(entry: WorkbookEntry) {
    try {
      await invoke("tab_open", { path: entry.path });
      chrome.mode = "doc";
    } catch (e) {
      console.warn("[grid] tab_open failed", e);
    }
  }

  // wb-h5yd / wb-dj5r — the create-workbook wizard runs inside the
  // palette modal, scoped to the active Package. Mirrors the HomePanel
  // "Workbook" chip; both surfaces drive the same `create-workbook`
  // server flow.
  let paletteOpen = $state(false);
  let paletteWizardMode = $state<{ id: string; title: string } | null>(null);
  function onCreateWorkbook() {
    paletteWizardMode = { id: "create-workbook", title: "Create a workbook" };
    paletteOpen = true;
  }
  function closePalette() {
    paletteOpen = false;
    paletteWizardMode = null;
  }
  function onWizardFinish() {
    // The wizard's follow-on session scaffolds the source tree; once
    // it lands a workbook file the grid should pick it up.
    void load();
  }
</script>

<div class="grid-host">
  {#if loading}
    <div class="empty muted">Loading workbooks…</div>
  {:else if error}
    <div class="empty err">{error}</div>
  {:else if entries.length === 0}
    <div class="empty centered">
      <span class="empty-glyph" aria-hidden="true">
        <FilePlus weight="fill" size={28} />
      </span>
      <p class="empty-title">No workbooks here yet</p>
      <p class="hint">
        Create one to get started, or switch to Tree view to see all
        files in this package.
      </p>
      <button type="button" class="cta" onclick={onCreateWorkbook}>
        <Plus weight="bold" size={14} />
        New workbook
      </button>
    </div>
  {:else}
    <div class="grid">
      {#each entries as entry (entry.path)}
        <button
          type="button"
          class="tile"
          aria-label={entry.title}
          draggable="true"
          ondragstart={(e) =>
            dnd.start(
              { type: "workbook", path: entry.path, title: entry.title },
              e,
            )}
          ondragend={() => dnd.end()}
          ondblclick={() => open(entry)}
          onkeydown={(e) => {
            if (e.key === "Enter") open(entry);
          }}
        >
          <span class="icon" aria-hidden="true">
            <img class="mi" src={fileIconUrl(entry.path)} alt="" />
          </span>
          <span class="title">{entry.title}</span>
        </button>
      {/each}
      <button
        type="button"
        class="tile new"
        aria-label="New workbook"
        onclick={onCreateWorkbook}
      >
        <span class="icon ghost" aria-hidden="true">
          <Plus weight="bold" size={20} />
        </span>
        <span class="title">New</span>
      </button>
    </div>
  {/if}
</div>

<PaletteModal
  open={paletteOpen}
  workdir={packageStore.active?.folders?.[0] ?? null}
  wizardMode={paletteWizardMode}
  onclose={closePalette}
  onwizardfinish={onWizardFinish}
/>

<style>
  .grid-host {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    padding: 12px;
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(74px, 1fr));
    gap: 12px 10px;
  }
  .tile {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    padding: 8px 4px 6px;
    border: 1px solid transparent;
    background: transparent;
    border-radius: 14px;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    transition:
      transform 0.35s cubic-bezier(0.2, 0.8, 0.2, 1),
      background 0.15s,
      border-color 0.15s;
  }
  .tile:hover {
    background: color-mix(in srgb, var(--color-surface) 88%, transparent);
    border-color: var(--color-border-strong);
    transform: translateY(-3px);
  }
  .tile:focus-visible {
    outline: 2px solid var(--color-ring);
    outline-offset: 1px;
  }
  .icon :global(.mi) {
    width: 28px;
    height: 28px;
    display: block;
  }
  .icon {
    width: 48px;
    height: 48px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 12px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    font-size: 22px;
    color: var(--color-fg);
  }
  .icon.ghost {
    background: transparent;
    border-style: dashed;
    color: var(--color-fg-muted);
  }
  .tile.new .title { color: var(--color-fg-muted); }
  .title {
    max-width: 76px;
    font-size: 11px;
    line-height: 1.25;
    text-align: center;
    word-break: break-word;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }
  .empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 32px 12px;
    text-align: center;
  }
  .empty.muted { color: var(--color-fg-muted); }
  .empty.err { color: var(--color-err); }
  .empty.centered {
    min-height: 100%;
    justify-content: center;
    gap: 12px;
    padding: 24px 16px;
    color: var(--color-fg-muted);
  }
  .empty-glyph {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 56px;
    height: 56px;
    border-radius: 14px;
    background: var(--color-surface-soft);
    border: 1px dashed var(--color-border);
    color: var(--color-fg-muted);
    margin-bottom: 4px;
  }
  .empty-title {
    margin: 0;
    font-size: 13px;
    font-weight: 500;
    color: var(--color-fg);
  }
  .empty .hint {
    margin: 0;
    font-size: 11px;
    line-height: 1.5;
    max-width: 220px;
  }
  .empty p { margin: 0; font-size: 12px; }
  .cta {
    margin-top: 8px;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 30px;
    padding: 0 12px;
    background: var(--color-fg);
    color: var(--color-page);
    border: 0;
    border-radius: 8px;
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition: filter 0.15s;
  }
  .cta:hover { filter: brightness(1.08); }
</style>
