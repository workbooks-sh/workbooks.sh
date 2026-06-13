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
  import { Check, Copy, Trash as Trash2, Palette } from "phosphor-svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { themes, type Theme } from "$lib/bridge/themes.svelte";
  import { nav } from "$lib/bridge/nav.svelte";
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
        <Copy weight="fill" size={13} /> Clone current
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
        <Check weight="bold" size={13} /> Save clone
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

  <!-- Layout preset (wb-aakl.16) — composable left navigation. -->
  <div class="layout-card">
    <span class="layout-label">Sidebar layout</span>
    <div class="layout-opts">
      {#each [["shelf", "Shelf"], ["hub", "Hub"], ["map", "Map"]] as [id, label] (id)}
        <button
          type="button"
          class="layout-opt"
          class:sel={nav.layout === id}
          onclick={() => nav.setLayout(id as "shelf" | "hub" | "map")}
        >
          {label}
        </button>
      {/each}
    </div>
  </div>

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
              <Check weight="bold" size={14} class="active-tick" />
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
              <Trash2 weight="fill" size={13} />
            </button>
          {/if}
        </article>
      {/each}
    </div>
  {/if}

  {#if opError}<div class="error">{opError}</div>{/if}
</SettingsPanel>

<style>
  .layout-card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 14px;
    margin-bottom: 14px;
    border: 1px solid var(--color-border);
    border-radius: 12px;
    background: var(--color-surface);
  }
  .layout-label {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }
  .layout-opts {
    margin-left: auto;
    display: flex;
    gap: 3px;
    padding: 3px;
    border: 1px solid var(--color-border);
    border-radius: 999px;
  }
  .layout-opt {
    border: 0;
    border-radius: 999px;
    padding: 5px 14px;
    background: transparent;
    color: var(--color-fg-muted);
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 500;
    cursor: pointer;
  }
  .layout-opt.sel {
    background: var(--color-fg);
    color: var(--color-page);
  }

  .new-row {
    display: flex;
    gap: 0.4rem;
    align-items: center;
  }
  .new-row input {
    flex: 1 1 auto;
    background: var(--color-page);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 0.4rem 0.6rem;
    font-size: 13px;
    color: var(--color-fg);
    font-family: var(--font-mono);
    outline: 0;
    transition: border-color 0.15s;
  }
  .new-row input:focus { border-color: var(--color-ring); }

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
    border-radius: 10px;
    padding: 0.45rem 0.5rem;
    transition: border-color 0.15s, background 0.15s;
  }
  .theme.active {
    border-color: var(--color-ring);
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
    font-family: var(--font-mono);
    font-size: 0.65rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 1px 6px;
    border-radius: 999px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-weight: 500;
  }
  .theme-body :global(.active-tick) {
    color: var(--color-brand);
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
    background: color-mix(in srgb, var(--color-err) 12%, transparent);
    color: var(--color-err);
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 28px;
    padding: 0 0.7rem;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 500;
    font-family: var(--font-mono);
    cursor: pointer;
    border: 1px solid transparent;
    transition: color 0.15s, background 0.15s, border-color 0.15s, filter 0.15s;
  }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.primary:hover:not(:disabled) { filter: brightness(1.08); }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover {
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .error {
    color: var(--color-err);
    font-size: 0.78rem;
  }
</style>
