<script lang="ts">
  /**
   * ThemesSettings — list + activate + clone + delete the desktop's
   * available themes. Each row shows a small swatch strip pulled from
   * the theme's most-distinctive tokens.
   *
   * Editing token values directly is intentionally NOT in v1 — the
   * inline-style application means anything you can tweak in dev-tools
   * round-trips; the right tool to author a full theme is your editor
   * against the on-disk `themes.org`. The "Clone current" button
   * captures the live `:root` state so you can use the running app as
   * the editor.
   */
  import { onMount } from "svelte";
  import { Check, Copy, Trash2, Palette } from "@lucide/svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { themes, type Theme } from "$lib/bridge/themes.svelte";
  import SettingsPanel from "./settings/SettingsPanel.svelte";
  import EmptyState from "./ui/EmptyState.svelte";

  let cloning = $state(false);
  let newName = $state("");
  let opError = $state<string | null>(null);

  onMount(() => {
    themes.init();
  });

  /** Pull the 4 most-distinctive token values for a preview strip. */
  function previewSwatches(t: Theme): string[] {
    // Prefer the dark variant when the OS is in dark mode, else light.
    const prefersDark =
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-color-scheme: dark)").matches;
    const src = prefersDark ? t.dark_tokens : t.light_tokens;
    const pick = (k: string) => src[k] ?? "transparent";
    return [
      pick("color-page"),
      pick("color-surface"),
      pick("color-fg"),
      pick("color-accent"),
    ];
  }

  async function activate(t: Theme) {
    opError = null;
    try {
      await themes.setActive(t.id);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function cloneCurrent() {
    const name = newName.trim();
    if (!name) return;
    opError = null;
    try {
      const snap = themes.snapshotCurrentTokens();
      await themes.create(name, "Cloned from current rendering", snap.light, snap.dark);
      newName = "";
      cloning = false;
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function deleteTheme(t: Theme) {
    if (t.builtin) return;
    if (!(await tauriConfirm(`Delete theme "${t.name}"?`, { kind: "warning" }))) return;
    try {
      await themes.delete(t.id);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }
</script>

<SettingsPanel
  title="Themes"
  lede="Switch the desktop's palette. Each theme carries a light + dark variant; the variant is picked automatically from your OS preference."
>
  {#snippet actions()}
    {#if !cloning}
      <button
        type="button"
        class="btn ghost"
        title="Capture the current rendering as a new theme"
        onclick={() => (cloning = true)}
      >
        <Copy size={13} strokeWidth={1.8} /> Clone current
      </button>
    {/if}
  {/snippet}

  {#if cloning}
    <form
      class="new-row"
      onsubmit={(e) => { e.preventDefault(); cloneCurrent(); }}
    >
      <input
        type="text"
        placeholder="Theme name"
        bind:value={newName}
        autofocus
      />
      <button type="submit" class="btn primary" disabled={!newName.trim()}>
        <Check size={13} strokeWidth={2.4} /> Save clone
      </button>
      <button
        type="button"
        class="btn ghost"
        onclick={() => { cloning = false; newName = ""; }}
      >
        Cancel
      </button>
    </form>
  {/if}

  {#if themes.themes.length === 0}
    <EmptyState
      icon={Palette}
      title="No themes yet"
      description="Built-in themes seed on first launch. Try restarting the desktop, or clone the current rendering to make your first one."
    />
  {:else}
    <div class="list">
      {#each themes.themes as t (t.id)}
        {@const swatches = previewSwatches(t)}
        {@const isActive = themes.activeId === t.id}
        <article class="theme" class:active={isActive}>
          <button
            type="button"
            class="theme-body"
            onclick={() => activate(t)}
            title={isActive ? "Active theme" : "Activate"}
          >
            <div class="swatches" aria-hidden="true">
              {#each swatches as c, i (i)}
                <span class="swatch" style="background: {c}"></span>
              {/each}
            </div>
            <div class="meta">
              <span class="name">
                {t.name}
                {#if t.builtin}<span class="chip">builtin</span>{/if}
              </span>
              {#if t.description}
                <span class="desc">{t.description}</span>
              {/if}
            </div>
            {#if isActive}
              <Check size={14} strokeWidth={2.4} class="active-tick" />
            {/if}
          </button>
          {#if !t.builtin}
            <button
              type="button"
              class="icon-btn danger"
              title="Delete theme"
              aria-label="Delete theme"
              onclick={() => deleteTheme(t)}
            >
              <Trash2 size={13} strokeWidth={1.8} />
            </button>
          {/if}
        </article>
      {/each}
    </div>
  {/if}

  {#if opError}<div class="error">{opError}</div>{/if}
</SettingsPanel>

<style>
  .new-row {
    display: flex;
    gap: 0.4rem;
    align-items: center;
  }
  .new-row input {
    flex: 1 1 auto;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    padding: 0.4rem 0.6rem;
    font-size: 0.85rem;
    color: var(--color-fg);
    font-family: inherit;
    outline: 0;
  }
  .new-row input:focus { border-color: var(--color-border-strong); }

  .list {
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
  }
  .theme {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 9px;
    padding: 0.45rem 0.5rem;
  }
  .theme.active {
    border-color: var(--color-border-strong);
    background: var(--color-surface);
  }
  .theme-body {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    gap: 0.7rem;
    background: transparent;
    border: 0;
    border-radius: 6px;
    padding: 0.3rem 0.5rem;
    cursor: pointer;
    color: var(--color-fg);
    font: inherit;
    text-align: left;
  }
  .theme-body:hover { background: var(--color-page); }
  .swatches {
    display: flex;
    gap: 2px;
    border: 1px solid var(--color-border);
    border-radius: 5px;
    overflow: hidden;
    flex-shrink: 0;
  }
  .swatch {
    width: 14px;
    height: 22px;
    display: inline-block;
  }
  .meta {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .name {
    font-size: 0.88rem;
    font-weight: 500;
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
  }
  .desc {
    font-size: 0.76rem;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .chip {
    font-size: 0.65rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 1px 6px;
    border-radius: 999px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-weight: 600;
  }
  .theme-body :global(.active-tick) {
    color: var(--color-fg);
    flex-shrink: 0;
  }

  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 5px;
    cursor: pointer;
    flex-shrink: 0;
  }
  .icon-btn:hover { background: var(--color-page); color: var(--color-fg); }
  .icon-btn.danger:hover {
    background: rgba(239, 68, 68, 0.12);
    color: #ef4444;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 28px;
    padding: 0 0.7rem;
    border-radius: 7px;
    font-size: 0.78rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    border: 1px solid transparent;
  }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover {
    background: var(--color-page);
    color: var(--color-fg);
  }
  .error {
    color: #ef4444;
    font-size: 0.78rem;
  }
</style>
