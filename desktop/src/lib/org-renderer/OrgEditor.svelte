<script lang="ts">
  /**
   * wb-i38o.10 — minimal org editor.
   *
   * Three view modes via the header toggle:
   *   - "render" (default): preview only, matches D9's read-only behavior
   *   - "split":            preview left, raw source right
   *   - "source":           raw source fills the pane
   *
   * Source pane is CodeMirror 6 plain-text. Cmd/Ctrl+S writes the
   * buffer back to disk via the `file_save` Tauri command (D10), which
   * also gates the write against the active workspace scope.
   *
   * Live re-render: the preview re-renders 250ms after the last
   * keystroke. We pipe `source` straight into <OrgView source=...>
   * (no disk round-trip).
   *
   * External-change detection: we listen for the `fs-tree-changed`
   * event the file-watcher emits and re-stat the file on focus. If
   * mtime moved AND the buffer is clean, we silently reload; if dirty,
   * we show a banner letting the user keep or discard.
   *
   * Tab dirty state is mirrored to the host so the TabStrip's
   * modified dot lights up.
   */
  import { invoke } from "@tauri-apps/api/core";
  import { listen, type UnlistenFn } from "@tauri-apps/api/event";
  import { onMount, onDestroy } from "svelte";
  import { Eye, Columns as Columns2, PencilSimple as Pencil, ShieldCheck } from "phosphor-svelte";
  import OrgView from "./OrgView.svelte";
  import OrgSourcePane from "./OrgSourcePane.svelte";
  import PortabilitySidebar from "$lib/components/PortabilitySidebar.svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import "./org.css";

  type Mode = "render" | "split" | "source";

  let { path, tabId }: { path: string; tabId?: string } = $props();

  let mode = $state<Mode>("render");
  let phase = $state<"loading" | "ready" | "error">("loading");
  let error = $state<string | null>(null);
  // Portability sidebar visibility — off by default; toggled from the
  // toolbar. The sidebar drives its own `work check --portability` call
  // off the file's parent directory when shown.
  let showPortability = $state<boolean>(false);

  // The workdir for the portability check is the file's parent dir —
  // `work check` walks a directory tree, not a single file.
  const workdir = $derived.by<string | null>(() => {
    if (!showPortability) return null;
    const idx = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
    return idx > 0 ? path.slice(0, idx) : null;
  });

  /** What's on disk (last load or last save). */
  let diskBuffer = $state<string>("");
  /** What the editor currently shows. */
  let liveBuffer = $state<string>("");
  /** mtime of the file at last load/save, ms since epoch. */
  let knownMtime = $state<number | null>(null);
  /** External change banner — set if disk moved while the buffer is dirty. */
  let externalChanged = $state(false);
  /** Debounced source the preview consumes. */
  let previewSource = $state<string>("");

  /** Monotonic key for the source pane — bumped on external reloads
   *  so CodeMirror remounts with the fresh disk buffer instead of
   *  retaining its stale doc. */
  let sourceEpoch = $state(0);
  let saving = $state(false);
  let lastError = $state<string | null>(null);

  let dirty = $derived(liveBuffer !== diskBuffer);

  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  let fsUnlisten: UnlistenFn | null = null;
  let saveUnlisten: UnlistenFn | null = null;

  async function statMtime(p: string): Promise<number | null> {
    try {
      return await invoke<number>("file_mtime", { path: p });
    } catch {
      return null;
    }
  }

  async function loadFromDisk(p: string): Promise<void> {
    phase = "loading";
    error = null;
    try {
      const [src, mt] = await Promise.all([
        invoke<string>("read_file_text", { path: p }),
        statMtime(p),
      ]);
      diskBuffer = src;
      liveBuffer = src;
      previewSource = src;
      knownMtime = mt;
      externalChanged = false;
      // Bump the source-pane key so CodeMirror remounts with the new
      // contents — CM's doc is not reactive once initialized.
      sourceEpoch += 1;
      phase = "ready";
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
      phase = "error";
    }
  }

  function scheduleLivePreview(next: string) {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      previewSource = next;
    }, 250);
  }

  // Auto-save kicks in 1.2s after the last keystroke so the user
  // doesn't have to think about saving. The save-state badge
  // surfaces the transition (Unsaved → Saving… → Saved). ⌘S still
  // works as a manual flush; it just isn't required.
  let autoSaveTimer: ReturnType<typeof setTimeout> | null = $state(null);
  function scheduleAutoSave() {
    if (autoSaveTimer) clearTimeout(autoSaveTimer);
    autoSaveTimer = setTimeout(() => {
      autoSaveTimer = null;
      if (dirty && !saving) void save();
    }, 1200);
  }

  function onSourceChange(next: string) {
    liveBuffer = next;
    scheduleLivePreview(next);
    scheduleAutoSave();
  }

  async function save() {
    if (saving) return;
    if (!dirty) return;
    saving = true;
    lastError = null;
    try {
      const result = await invoke<{ mtime_ms: number }>("file_save", {
        path,
        contents: liveBuffer,
      });
      diskBuffer = liveBuffer;
      knownMtime = result.mtime_ms;
      externalChanged = false;
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
    } finally {
      saving = false;
    }
  }

  async function discardAndReload() {
    await loadFromDisk(path);
  }

  function dismissExternalBanner() {
    externalChanged = false;
  }

  /** Re-check mtime when the watcher fires for this file's root. */
  async function checkExternalChange() {
    if (phase !== "ready") return;
    const mt = await statMtime(path);
    if (mt === null || knownMtime === null) return;
    if (mt <= knownMtime) return;
    // Disk advanced.
    if (!dirty) {
      // Clean buffer — silently reload.
      await loadFromDisk(path);
    } else {
      externalChanged = true;
    }
  }

  function onWindowFocus() {
    void checkExternalChange();
  }

  onMount(async () => {
    await loadFromDisk(path);
    // fs-tree-changed is per-root, not per-file; check on every fire.
    fsUnlisten = await listen("fs-tree-changed", () => {
      void checkExternalChange();
    });
    // Also listen for our own file-saved event in case another tab
    // (or the agent) wrote the same file.
    saveUnlisten = await listen<{ path: string; mtime_ms: number }>(
      "file-saved",
      (e) => {
        if (e.payload.path === path) {
          // We saved it — already updated locally. If a peer saved it,
          // mtime will be ahead; checkExternalChange handles that.
          if (knownMtime !== null && e.payload.mtime_ms > knownMtime) {
            void checkExternalChange();
          }
        }
      },
    );
    window.addEventListener("focus", onWindowFocus);
  });

  onDestroy(() => {
    if (debounceTimer) clearTimeout(debounceTimer);
    fsUnlisten?.();
    saveUnlisten?.();
    window.removeEventListener("focus", onWindowFocus);
  });

  // Mirror the dirty flag to the Rust-owned tab state so the
  // TabStrip's modified dot lights up consistently across components.
  $effect(() => {
    if (!tabId) return;
    void invoke("tab_set_dirty", { id: tabId, dirty });
  });

  // Re-load if path changes (same component instance, different file —
  // shouldn't happen with TabbedViewer's #key, but defensive).
  $effect(() => {
    if (path) void loadFromDisk(path);
  });

  function pathCrumb(p: string): string {
    // Trim to the last two segments for compactness; full path is the tooltip.
    const parts = p.split(/[\\/]/);
    return parts.slice(-2).join("/");
  }
</script>

<div class="editor">
  <div class="toolbar" role="toolbar" aria-label="Org view mode">
    <div class="path-crumb" title={path}>
      {pathCrumb(path)}
      {#if dirty}<span class="dirty-dot" aria-label="modified"></span>{/if}
    </div>

    <div class="mode-group" role="radiogroup" aria-label="View mode">
      <button
        type="button"
        class="mode-btn"
        class:active={mode === "render"}
        role="radio"
        aria-checked={mode === "render"}
        aria-label="Render only"
        title="Render only"
        onclick={() => (mode = "render")}
      >
        <Eye weight="fill" size={14} />
      </button>
      <button
        type="button"
        class="mode-btn"
        class:active={mode === "split"}
        role="radio"
        aria-checked={mode === "split"}
        aria-label="Split — preview + source"
        title="Split — preview + source"
        onclick={() => (mode = "split")}
      >
        <Columns2 weight="fill" size={14} />
      </button>
      <button
        type="button"
        class="mode-btn"
        class:active={mode === "source"}
        role="radio"
        aria-checked={mode === "source"}
        aria-label="Source only"
        title="Source only"
        onclick={() => (mode = "source")}
      >
        <Pencil weight="fill" size={14} />
      </button>
    </div>

    <!--
      Save state is a faint badge, not an action. The file
      auto-saves on every keystroke (see `onSourceChange` debounce);
      ⌘S still works as a manual flush. Showing a button-shaped
      "Save" implies the user has to confirm, which they don't.
    -->
    <span
      class="save-state"
      class:saving
      class:dirty
      title={saving ? "Saving…" : dirty ? "Unsaved changes — auto-saves on idle" : "All changes saved"}
    >
      {saving ? "Saving…" : dirty ? "Unsaved" : "Saved"}
    </span>

    <!-- Portability sidebar toggle (wb-unzn.25 P3). Surfaces the
         workbook's tier + per-cell classification in a right-rail
         pane. Read-only — never mutates the workbook source. -->
    <button
      type="button"
      class="mode-btn portability-toggle"
      class:active={showPortability}
      aria-pressed={showPortability}
      aria-label="Toggle portability sidebar"
      title="Toggle portability sidebar"
      onclick={() => (showPortability = !showPortability)}
    >
      <ShieldCheck weight="fill" size={14} />
    </button>
  </div>

  {#if externalChanged}
    <div class="banner" role="alert">
      <span>File changed on disk while you were editing.</span>
      <div class="banner-actions">
        <button type="button" class="banner-btn" onclick={discardAndReload}>
          Discard &amp; reload
        </button>
        <button type="button" class="banner-btn ghost" onclick={dismissExternalBanner}>
          Keep editing
        </button>
      </div>
    </div>
  {/if}

  {#if lastError}
    <div class="banner err" role="alert">
      <span>Save failed: {lastError}</span>
      <button type="button" class="banner-btn ghost" onclick={() => (lastError = null)}>
        Dismiss
      </button>
    </div>
  {/if}

  {#if phase === "loading"}
    <div class="status">Loading…</div>
  {:else if phase === "error"}
    <div class="status err">Failed to read: {error}</div>
  {:else}
    <div class="layout" class:with-sidebar={showPortability}>
      <div class="panes" class:split={mode === "split"}>
        {#if mode === "render" || mode === "split"}
          <div class="pane preview">
            <OrgView source={previewSource} showPathHeader={false} />
          </div>
        {/if}
        {#if mode === "source" || mode === "split"}
          <div class="pane source">
            {#key sourceEpoch}
              <OrgSourcePane
                initial={diskBuffer}
                onChange={onSourceChange}
                onSave={save}
              />
            {/key}
          </div>
        {/if}
      </div>
      {#if showPortability}
        <!-- TODO(wb-unzn.25 P3): inline per-cell badges in the
             render/source panes. The current OQL → HTML pipeline
             (lib/org-renderer/render.ts) doesn't expose SRC-block
             line numbers, so threading a badge into the rendered
             output safely requires a transform pass that knows where
             #+BEGIN_SRC lines land. Shipping the sidebar alone gives
             the user the same information for now. -->
        <div class="sidebar-pane">
          <PortabilitySidebar workdir={workdir} />
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .editor {
    flex: 1 1 auto;
    min-height: 0;
    min-width: 0;
    display: flex;
    flex-direction: column;
  }
  .toolbar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.4rem 0.85rem;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface);
    flex-shrink: 0;
  }
  .path-crumb {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 12px;
    color: var(--color-fg-muted);
    font-family: var(--font-mono), ui-monospace, monospace;
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .dirty-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-fg);
    flex-shrink: 0;
  }
  .mode-group {
    display: inline-flex;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    overflow: hidden;
  }
  /* Icon-only tri-state for view mode. No text labels — title attr
   * carries the accessible name + tooltip. */
  .mode-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 24px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    border-right: 1px solid var(--color-border);
    transition: background 0.15s, color 0.15s;
  }
  .mode-btn:last-child { border-right: 0; }
  .mode-btn:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .mode-btn.active {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  /* Save state is informational, not actionable — render it as a
   * faint label, not a button. Auto-save handles the actual write
   * 1.2s after the last keystroke. */
  .save-state {
    display: inline-flex;
    align-items: center;
    height: 24px;
    padding: 0 0.5rem;
    color: var(--color-fg-subtle);
    font-size: 0.72rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    user-select: none;
  }
  .save-state.dirty { color: var(--color-fg-muted); }
  .save-state.saving { color: var(--color-fg-muted); }
  .banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.5rem 0.85rem;
    background: color-mix(in srgb, var(--color-warn) 12%, transparent);
    border-bottom: 1px solid color-mix(in srgb, var(--color-warn) 40%, transparent);
    color: var(--color-fg);
    font-size: 12.5px;
    flex-shrink: 0;
  }
  .banner.err {
    /* var(--color-err) = app-wide error literal — no error token in the canon */
    background: color-mix(in srgb, var(--color-err) 12%, transparent);
    border-bottom-color: color-mix(in srgb, var(--color-err) 40%, transparent);
  }
  .banner-actions {
    display: inline-flex;
    gap: 0.4rem;
  }
  .banner-btn {
    padding: 0.25rem 0.6rem;
    background: var(--color-fg);
    color: var(--color-page);
    border: 0;
    border-radius: 8px;
    font-size: 11.5px;
    font-family: inherit;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }
  .banner-btn.ghost {
    background: transparent;
    color: var(--color-fg);
    border: 1px solid var(--color-border);
  }
  .status {
    padding: 1rem 1.5rem;
    font-size: 0.9rem;
    color: var(--color-fg-muted);
  }
  .status.err {
    color: var(--color-err); /* app-wide error literal — no error token in the canon */
    font-family: var(--font-mono), ui-monospace, monospace;
    white-space: pre-wrap;
  }
  .layout {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: row;
  }
  .layout.with-sidebar .panes {
    border-right: 1px solid var(--color-border);
  }
  .sidebar-pane {
    flex: 0 0 320px;
    min-width: 0;
    overflow: auto;
    padding: 0.85rem;
    background: var(--color-page);
  }
  .panes {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: row;
  }
  .portability-toggle {
    border: 1px solid var(--color-border);
    border-radius: 8px;
    width: 26px;
    height: 24px;
    background: transparent;
    color: var(--color-fg-muted);
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .portability-toggle:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .portability-toggle.active {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .pane {
    flex: 1 1 0;
    min-width: 0;
    min-height: 0;
    overflow: auto;
    display: flex;
    flex-direction: column;
  }
  .panes.split .pane.preview {
    border-right: 1px solid var(--color-border);
  }
  .pane.source {
    overflow: hidden;
  }
</style>
