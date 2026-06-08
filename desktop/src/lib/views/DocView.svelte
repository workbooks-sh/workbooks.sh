<script lang="ts">
  /**
   * DocView — the document surface for the active tab (chrome.mode === "doc").
   *
   * The host (tabs.rs) owns the open list; this view renders whichever tab is
   * focused. It mirrors the workbook model: a workbook is a self-contained .html
   * (the HTML *is* the render); an .org is raw source the embedded oql.wasm kernel
   * weaves to HTML; everything else is just source.
   *
   * Two views, toggled in the bar:
   *   - Preview — the render. .org → woven HTML (live, in-process); .html workbook
   *     → the HTML itself in a sandboxed iframe. Default when a render exists.
   *   - Source  — the raw text (org / html / code). Default when there is NO render
   *     (markdown, code, plain context files). Edits set the tab dirty; ⌘S saves.
   *
   * Replaces the old "Document viewer lands here" placeholder (wb-jay.7).
   */
  import { CircleCheck, CircleAlert, Save, Eye, MoreHorizontal } from "@lucide/svelte";
  import { tabs } from "$lib/tabs.svelte";
  import { commands } from "$lib/bindings";
  import { weave, validate, outline, hasLocalKernel } from "$lib/kernel";
  import { readFileText, saveWorkbook } from "$lib/files";

  interface Headline {
    level: number;
    title: string;
    state?: string | null;
    tags?: string[];
  }

  type ViewMode = "preview" | "source";

  let loadedId = $state<string | null>(null);
  let text = $state("");
  let html = $state("");
  let issues = $state<number | null>(null);
  let headlines = $state<Headline[]>([]);
  let err = $state("");
  let loading = $state(false);
  let mode = $state<ViewMode>("preview");

  const active = $derived(tabs.active);
  // What kind of render (if any) this tab has.
  const renderAs = $derived<"weave" | "html" | null>(
    active?.kind === "org" ? "weave" : active?.kind === "workbook" ? "html" : null,
  );
  const renderable = $derived(renderAs !== null);

  // Load the active tab's content whenever the focused tab changes.
  $effect(() => {
    const t = tabs.active;
    if (!t) {
      loadedId = null;
      text = "";
      html = "";
      issues = null;
      headlines = [];
      return;
    }
    if (t.id === loadedId) return;
    loadedId = t.id;
    // Default to the render if there is one, else straight to source.
    mode = t.kind === "org" || t.kind === "workbook" ? "preview" : "source";
    void load(t.path);
  });

  async function load(path: string) {
    err = "";
    loading = true;
    html = "";
    issues = null;
    headlines = [];
    try {
      text = await readFileText(path);
      if (renderAs === "weave") await refresh();
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
      text = "";
    } finally {
      loading = false;
    }
  }

  let timer: ReturnType<typeof setTimeout> | undefined;
  function onInput() {
    const t = tabs.active;
    if (t && !t.dirty) void commands.tabSetDirty({ id: t.id, dirty: true });
    if (renderAs !== "weave" || !hasLocalKernel()) return;
    clearTimeout(timer);
    timer = setTimeout(() => void refresh(), 250);
  }

  async function refresh() {
    err = "";
    try {
      html = await weave(text);
      const diag = (await validate(text)) as unknown[];
      issues = Array.isArray(diag) ? diag.length : null;
      headlines = (await outline(text)) as Headline[];
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
    }
  }

  async function save() {
    const t = tabs.active;
    if (!t) return;
    try {
      await saveWorkbook(text, t.path);
      await commands.tabSetDirty({ id: t.id, dirty: false });
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
    }
  }

  function onKey(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
      e.preventDefault();
      void save();
    }
  }
</script>

<svelte:window onkeydown={onKey} />

{#if active}
  <section class="doc">
    <div class="bar">
      <span class="title">{active.title}</span>
      <span class="path" title={active.path}>{active.path}</span>

      {#if renderAs === "weave" && issues !== null}
        <span class="status" class:ok={issues === 0}>
          {#if issues === 0}<CircleCheck size={14} />valid{:else}<CircleAlert size={14} />{issues} issue{issues === 1 ? "" : "s"}{/if}
        </span>
      {/if}

      <span class="spacer"></span>
      {#if renderable}
        <!-- Source/edit is secondary: the render is the point. A quiet toggle, not a pill. -->
        <button class="icon" onclick={() => (mode = mode === "preview" ? "source" : "preview")}
          title={mode === "preview" ? "View source" : "Back to preview"}
          aria-label={mode === "preview" ? "View source" : "Back to preview"}>
          {#if mode === "preview"}<MoreHorizontal size={16} strokeWidth={1.8} />{:else}<Eye size={15} strokeWidth={1.8} />{/if}
        </button>
      {/if}
      <button class="ghost" onclick={() => void save()} title="Save (⌘S)" disabled={!active.dirty}>
        <Save size={15} strokeWidth={1.8} />
        Save
      </button>
    </div>

    {#if err}<p class="err">{err}</p>{/if}
    {#if loading}<p class="muted">Loading…</p>{/if}

    <!-- PREVIEW: the render. -->
    {#if renderable && mode === "preview"}
      {#if renderAs === "weave"}
        <div class="body">
          <nav class="outline" aria-label="workbook outline">
            {#each headlines as h}
              <div class="hl" style="padding-left:{(h.level - 1) * 0.7 + 0.1}rem" title={h.title}>
                {#if h.state}<em class="hl-state">{h.state}</em>{/if}{h.title}
              </div>
            {/each}
            {#if headlines.length === 0}<div class="hl muted">no headlines</div>{/if}
          </nav>
          <article class="render">{@html html}</article>
        </div>
      {:else}
        <!-- A workbook is self-contained HTML; sandbox it so it can't reach the shell. -->
        <iframe class="wb-frame" title={active.title} sandbox="allow-scripts" srcdoc={text}></iframe>
      {/if}
    {:else}
      <!-- SOURCE: raw text, editable. The default for non-rendering files. -->
      <textarea class="source" bind:value={text} oninput={onInput} spellcheck="false"></textarea>
    {/if}
  </section>
{:else}
  <div class="empty">
    <p>No document open.</p>
    <p class="muted">Open a file (folder icon, search, or bookmarks) to start.</p>
  </div>
{/if}

<style>
  .doc {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    padding: 1rem;
    height: 100%;
    overflow: hidden;
  }
  .bar { display: flex; align-items: center; gap: 0.6rem; flex: none; }
  .title { font-weight: 600; font-size: 0.92rem; }
  .path {
    font-size: 0.75rem; color: var(--color-fg-subtle);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 32ch;
  }
  .spacer { flex: 1; }
  .icon {
    display: inline-flex; align-items: center; justify-content: center;
    width: 28px; height: 28px; border-radius: 6px; cursor: pointer;
    border: 0; background: transparent; color: var(--color-fg-muted);
  }
  .icon:hover { background: var(--color-surface-soft); color: var(--color-fg); }
  .ghost {
    display: inline-flex; align-items: center; gap: 0.4rem;
    padding: 0.35rem 0.7rem; border-radius: 6px; cursor: pointer;
    border: 1px solid var(--color-border); background: var(--color-page);
    color: var(--color-fg); font-size: 0.82rem;
  }
  .ghost:disabled { opacity: 0.45; cursor: default; }
  .status {
    display: inline-flex; align-items: center; gap: 0.3rem;
    font-size: 0.78rem; padding: 0.15rem 0.45rem; border-radius: 999px;
    background: color-mix(in srgb, var(--color-err) 14%, transparent); color: var(--color-err);
  }
  .status.ok {
    background: color-mix(in srgb, var(--color-ok) 14%, transparent); color: var(--color-ok);
  }
  .body { display: flex; gap: 0.75rem; flex: 1; min-height: 0; }
  .outline {
    width: 180px; flex: none; overflow: auto;
    border-right: 1px solid var(--color-border);
    padding-right: 0.5rem; font-size: 0.82rem;
  }
  .hl { padding: 0.15rem 0.25rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; border-radius: 4px; }
  .hl-state { color: var(--color-warn); font-style: normal; font-size: 0.72rem; margin-right: 0.35rem; }
  .muted { opacity: 0.5; }
  .render {
    flex: 1 1 auto; overflow: auto;
    border: 1px solid var(--color-border); border-radius: 8px;
    padding: 1rem 1.25rem; background: var(--color-surface);
  }
  .wb-frame {
    flex: 1 1 auto; width: 100%; border: 1px solid var(--color-border);
    border-radius: 8px; background: #fff; min-height: 0;
  }
  .source {
    flex: 1 1 auto; min-height: 8rem; resize: none;
    padding: 0.6rem 0.75rem; border: 1px solid var(--color-border);
    border-radius: 8px; background: transparent; color: inherit;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.85rem; line-height: 1.5;
  }
  .err { color: var(--color-err); font-size: 0.9rem; }
  .empty {
    display: flex; flex-direction: column; gap: 0.4rem; align-items: center;
    justify-content: center; height: 100%; color: var(--color-fg-subtle);
  }
</style>
