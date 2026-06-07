<script lang="ts">
  /**
   * WorkbookView — the app renders its own format. The LOCAL embedded kernel
   * (oql.wasm) weaves Org → HTML in-process: no runtime, no Docker, offline. A
   * stored workbook can also be pulled from the runtime by id WHEN connected
   * (optional server tier), but the default path needs nothing.
   */
  import { FileText, Cloud, CircleCheck, CircleAlert, FolderOpen, Save } from "@lucide/svelte";
  import { weave, validate, outline, hasLocalKernel } from "$lib/kernel";
  import { openWorkbook, saveWorkbook } from "$lib/files";
  import { rt, getRuntime } from "$lib/runtime";

  interface Headline {
    level: number;
    title: string;
    state?: string | null;
    tags?: string[];
  }
  let headlines = $state<Headline[]>([]);

  let path = $state<string | null>(null);

  async function open() {
    const doc = await openWorkbook();
    if (doc) {
      org = doc.org;
      path = doc.path;
      void refresh();
    }
  }

  async function save() {
    const p = await saveWorkbook(org, path ?? undefined);
    if (p) path = p;
  }

  const sample = "* My Workbook\n\nThe app renders *its own format* — live, locally, via the\nembedded =oql.wasm= kernel. No server required.\n\n** A list\n- weave\n- tangle\n- validate\n";

  let org = $state(sample);
  let html = $state("");
  let err = $state("");
  let issues = $state<number | null>(null);

  // Live edit→preview: debounced weave + validate as you type, fully in-process.
  let timer: ReturnType<typeof setTimeout> | undefined;
  function onInput() {
    if (!hasLocalKernel()) {
      err = "Live weave needs the desktop shell (oql.wasm).";
      return;
    }
    clearTimeout(timer);
    timer = setTimeout(() => void refresh(), 250);
  }

  async function refresh() {
    err = "";
    try {
      html = await weave(org);
      const diag = (await validate(org)) as unknown[];
      issues = Array.isArray(diag) ? diag.length : null;
      headlines = (await outline(org)) as Headline[];
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
    }
  }

  $effect(() => {
    if (hasLocalKernel()) void refresh();
  });

  // Optional: pull a stored workbook's woven HTML from the runtime (when up).
  async function loadFromRuntime(id: string) {
    err = "";
    try {
      const info = await getRuntime();
      if (info.state !== "up") {
        err = "Runtime not connected (the optional server tier).";
        return;
      }
      const res = await rt(`/api/w/${encodeURIComponent(id)}/html`);
      if (!res.ok) {
        err = `runtime → HTTP ${res.status}`;
        return;
      }
      html = await res.text();
      issues = null;
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
    }
  }

  let id = $state("");
</script>

<section class="workbook">
  <div class="bar">
    <FileText size={18} strokeWidth={1.6} />
    <button class="ghost" onclick={() => void open()}>
      <FolderOpen size={15} strokeWidth={1.8} />
      Open
    </button>
    <button class="ghost" onclick={() => void save()}>
      <Save size={15} strokeWidth={1.8} />
      Save
    </button>
    <span class="title">{path ? path.split("/").pop() : "untitled.org"}</span>
    {#if issues !== null}
      <span class="status" class:ok={issues === 0}>
        {#if issues === 0}<CircleCheck size={14} />valid{:else}<CircleAlert size={14} />{issues} issue{issues === 1 ? "" : "s"}{/if}
      </span>
    {/if}
    <span class="spacer"></span>
    <input bind:value={id} placeholder="stored id (runtime)" />
    <button class="ghost" disabled={!id} onclick={() => void loadFromRuntime(id)}>
      <Cloud size={15} strokeWidth={1.8} />
      From runtime
    </button>
  </div>

  <div class="body">
    <nav class="outline" aria-label="workbook outline">
      {#each headlines as h}
        <div class="hl" style="padding-left:{(h.level - 1) * 0.7 + 0.1}rem" title={h.title}>
          {#if h.state}<em class="hl-state">{h.state}</em>{/if}{h.title}
        </div>
      {/each}
      {#if headlines.length === 0}<div class="hl muted">no headlines</div>{/if}
    </nav>

    <div class="main">
      <textarea bind:value={org} oninput={onInput} spellcheck="false"></textarea>

      {#if err}
        <p class="err">{err}</p>
      {/if}

      {#if html}
        <!-- HTML woven by the local kernel (or runtime) from Org, rendered verbatim. -->
        <article class="woven">{@html html}</article>
      {/if}
    </div>
  </div>
</section>

<style>
  .workbook {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 1rem;
    height: 100%;
    overflow: auto;
  }
  .bar {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .bar input {
    flex: 1;
    padding: 0.4rem 0.6rem;
    border: 1px solid var(--border, #2a2a2a);
    border-radius: 6px;
    background: transparent;
    color: inherit;
  }
  .bar button {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.4rem 0.7rem;
    border-radius: 6px;
    cursor: pointer;
  }
  .bar button.ghost {
    opacity: 0.8;
  }
  .spacer {
    flex: 1;
  }
  .title {
    font-size: 0.9rem;
    opacity: 0.75;
  }
  .status {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    font-size: 0.78rem;
    padding: 0.15rem 0.45rem;
    border-radius: 999px;
    background: #e06c7522;
    color: #e06c75;
  }
  .status.ok {
    background: #98c37922;
    color: #98c379;
  }
  .body {
    display: flex;
    gap: 0.75rem;
    flex: 1;
    min-height: 0;
  }
  .outline {
    width: 180px;
    flex: none;
    overflow: auto;
    border-right: 1px solid var(--border, #2a2a2a);
    padding-right: 0.5rem;
    font-size: 0.82rem;
  }
  .hl {
    padding: 0.15rem 0.25rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    border-radius: 4px;
    cursor: default;
  }
  .hl:hover {
    background: #ffffff10;
  }
  .hl-state {
    color: #d19a66;
    font-style: normal;
    font-size: 0.72rem;
    margin-right: 0.35rem;
  }
  .muted {
    opacity: 0.4;
  }
  .main {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    flex: 1;
    min-width: 0;
  }
  textarea {
    min-height: 9rem;
    resize: vertical;
    padding: 0.6rem 0.75rem;
    border: 1px solid var(--border, #2a2a2a);
    border-radius: 8px;
    background: transparent;
    color: inherit;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.85rem;
    line-height: 1.5;
  }
  .err {
    color: #e06c75;
    font-size: 0.9rem;
  }
  .woven {
    border: 1px solid var(--border, #2a2a2a);
    border-radius: 8px;
    padding: 1rem 1.25rem;
    background: var(--surface, #1116);
  }
</style>
