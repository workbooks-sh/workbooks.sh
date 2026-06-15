<script lang="ts">
  /**
   * AgentTabView — the AgentDef editor as a workbook TAB (feat/agent-tab).
   *
   * The agent IS a workbook: this opens via the normal tab system
   * (path `agent://<slug>`) and renders inside DocViewer, not as a
   * modal. It surfaces the agent's identity + settings, a
   * human-in-the-loop toggle, and an action to publish/send the agent.
   *
   * Save logic mirrors the legacy modal AgentEditor (agents_read /
   * agents_create / agents_patch over the host seam), but the surface
   * is a full-bleed two-column document, dirty-tracked through the
   * tabs store (so the tab shows a dot + the strip warns on close).
   */
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import {
    Trash as Trash2,
    FloppyDisk as Save,
    PaperPlaneTilt as Publish,
    UsersThree as HumanLoop,
    Star,
    CheckCircle,
  } from "phosphor-svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { agents } from "$lib/bridge/agents.svelte";
  import { agentSettings } from "$lib/bridge/agent_settings.svelte";
  import { tabs } from "$lib/tabs/store.svelte";
  import { agentSlugFromPath, agentTabPath } from "$lib/tabs/agentTab";
  import AgentIconPicker from "$lib/chat/AgentIconPicker.svelte";
  import ModelPicker from "$lib/chat/ModelPicker.svelte";
  import ChipMultiSelect from "$lib/chat/ChipMultiSelect.svelte";

  let { path, tabId }: { path: string; tabId: string } = $props();

  const slug = $derived(agentSlugFromPath(path));
  const isNew = $derived(slug === "__new__");

  const AVAILABLE_PACKAGES = [
    "bash", "wb", "lua", "wavelet", "brandnana",
    "git", "cargo", "npm", "pnpm", "node",
    "gws", "claude", "codex", "composio", "doppler", "fal",
  ];

  // ── editor fields ──────────────────────────────────────────────
  let title = $state("");
  let tagline = $state("");
  let slugValue = $state("");
  let model = $state("");
  let icon = $state("");
  let systemPrompt = $state("");
  let packagesText = $state("");
  // Human-in-the-loop: agent pauses for human approval before acting.
  // Persisted on the .org as the :HUMAN_IN_LOOP: drawer property.
  let humanInLoop = $state(false);

  let scope = $state<"user" | "project" | "builtin" | null>(null);
  let busy = $state(false);
  let publishing = $state(false);
  let error = $state<string | null>(null);
  let status = $state<string | null>(null);
  let slugManuallyEdited = $state(false);
  let loaded = $state(false);

  const isReadOnly = $derived(scope === "builtin" || scope === "project");
  const isPinned = $derived(
    !isNew && slugValue === agentSettings.settings.default_agent_slug,
  );

  // ── load ───────────────────────────────────────────────────────
  onMount(() => {
    void agents.init();
    void agentSettings.init();
    void load();
  });

  async function load() {
    error = null;
    if (isNew) {
      title = "New agent";
      packagesText = "bash wb";
      model = "";
      scope = "user";
      humanInLoop = false;
      loaded = true;
      baseline = snapshotFields();
      return;
    }
    try {
      // Catalog may not be ready on first paint; refresh then read.
      if (agents.agents.length === 0) await agents.refresh().catch(() => {});
      const entry = agents.agents.find((a) => a.slug === slug);
      if (!entry) {
        // Still attempt a direct read — the file may exist before the
        // catalog enriches.
        scope = "user";
      } else {
        scope = entry.scope;
        title = entry.title ?? entry.slug;
        tagline = entry.tagline ?? "";
        icon = entry.icon ?? "";
        model = entry.model ?? "";
        packagesText = (entry.toolkits ?? entry.packages ?? []).join(" ");
      }
      slugValue = slug ?? "";
      try {
        const file = await invoke<{ source: string }>("agents_read", { slug });
        systemPrompt = extractSystemPrompt(file.source);
        humanInLoop = readBoolProp(file.source, "HUMAN_IN_LOOP");
        if (!title) title = slugValue;
      } catch {
        systemPrompt = entry?.system_prompt_preview ?? "";
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loaded = true;
      baseline = snapshotFields();
    }
  }

  function snapshotFields(): string {
    return JSON.stringify({
      title, tagline, slugValue, model, icon, systemPrompt,
      packagesText, humanInLoop,
    });
  }

  function extractSystemPrompt(src: string): string {
    const m = src.match(
      /\*\*\s+System prompt\s*\n([\s\S]*?)(?=\n\*\*[^*]|\n\*[^*]|$)/,
    );
    return m ? m[1].trim() : "";
  }
  function readBoolProp(src: string, name: string): boolean {
    const m = src.match(new RegExp(`^\\s*:${name}:\\s+([^\\n]*)$`, "m"));
    return m ? /^(t|true|yes|on|1)$/i.test(m[1].trim()) : false;
  }

  // Auto-slug from title in new mode.
  $effect(() => {
    if (!isNew || slugManuallyEdited) return;
    slugValue = title
      .toLowerCase().trim()
      .replace(/[^a-z0-9-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .replace(/-{2,}/g, "-");
  });

  // Dirty-track the tab once loaded. Any field change marks dirty so
  // the strip shows a dot + warns on close. `baseline` is set by load()
  // / save() (never inside this effect — a self-writing effect loops).
  // The effect only READS baseline + the fields and pushes the verdict
  // to the host; it guards against redundant setDirty churn (setDirty
  // rebuilds the tabs array, which must not feed back into here).
  let baseline = $state<string | null>(null);
  let lastDirtyPushed: boolean | null = null;
  const currentSnapshot = $derived(
    JSON.stringify({
      title, tagline, slugValue, model, icon, systemPrompt,
      packagesText, humanInLoop,
    }),
  );
  $effect(() => {
    if (!loaded || baseline === null) return;
    const dirty = currentSnapshot !== baseline;
    if (dirty === lastDirtyPushed) return;
    lastDirtyPushed = dirty;
    void tabs.setDirty(tabId, dirty);
  });

  // ── build / save ───────────────────────────────────────────────
  function buildOrgFromScratch(): string {
    const pkgs = packagesText.split(/\s+/).filter(Boolean).join(" ");
    const extra: string[] = [];
    if (icon.trim()) extra.push("ICON");
    if (tagline.trim()) extra.push("TAGLINE");
    if (pkgs.length) extra.push("TOOLKITS");
    const extensions = extra.length
      ? `#+EXTENSIONS: ${extra.join(" ")}\n\n`
      : "";
    const lines: string[] = [];
    lines.push(`* ${title.trim() || slugValue}                                                          :agent:`);
    lines.push(`  :PROPERTIES:`);
    lines.push(`  :ID:           ${slugValue}`);
    lines.push(`  :TYPE:         ai`);
    if (model.trim()) lines.push(`  :MODEL:        ${model.trim()}`);
    if (icon.trim()) lines.push(`  :ICON:         ${icon.trim()}`);
    if (tagline.trim()) lines.push(`  :TAGLINE:      ${tagline.trim()}`);
    if (pkgs.length) lines.push(`  :TOOLKITS:     ${pkgs}`);
    lines.push(`  :HUMAN_IN_LOOP: ${humanInLoop ? "true" : "false"}`);
    lines.push(`  :END:`);
    if (systemPrompt.trim()) {
      lines.push(`** System prompt`);
      lines.push(systemPrompt.trim());
    }
    return extensions + lines.join("\n") + "\n";
  }

  async function save(): Promise<boolean> {
    if (isReadOnly || busy) return false;
    error = null;
    status = null;
    if (!slugValue.trim()) {
      error = "Slug cannot be empty.";
      return false;
    }
    busy = true;
    try {
      if (isNew) {
        await invoke("agents_create", {
          req: { slug: slugValue, source: buildOrgFromScratch() },
        });
      } else {
        await invoke<{ source: string }>("agents_patch", {
          req: {
            slug: slugValue,
            properties: {
              MODEL: model.trim(),
              ICON: icon.trim(),
              TAGLINE: tagline.trim(),
              TOOLKITS: packagesText.trim(),
              HUMAN_IN_LOOP: humanInLoop ? "true" : "false",
              PACKAGES: "",
            },
            title: title.trim() || null,
            system_prompt: systemPrompt,
          },
        });
      }
      await agents.refresh().catch(() => {});
      baseline = snapshotFields();
      lastDirtyPushed = false;
      await tabs.setDirty(tabId, false);
      // A freshly-created agent's tab path changes from __new__ to its
      // real slug; reopen under the canonical path + close the draft.
      if (isNew) {
        const draftId = tabId;
        await tabs.open(agentTabPath(slugValue));
        await tabs.close(draftId);
      }
      status = "Saved";
      return true;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      return false;
    } finally {
      busy = false;
    }
  }

  // Publish / send — save first, then push the agent to the runtime so
  // it becomes available to sessions (and, when configured, shared to
  // the workspace nexus). Best-effort over the host seam.
  async function publish() {
    if (publishing || isReadOnly) return;
    error = null;
    status = null;
    const ok = await save();
    if (!ok && !isNew && error) return;
    publishing = true;
    try {
      const res = await invoke<{ ok: boolean; url?: string }>(
        "agent_publish",
        { slug: slugValue },
      );
      status = res?.url ? `Published → ${res.url}` : "Published to runtime";
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      publishing = false;
    }
  }

  async function togglePin() {
    if (isNew) return;
    await agentSettings.setDefaultAgent(isPinned ? "" : slugValue);
  }

  async function del() {
    if (isNew || scope !== "user") return;
    if (!(await tauriConfirm(`Delete agent "${slugValue}"? This cannot be undone.`, { kind: "warning" }))) return;
    busy = true;
    try {
      await invoke("agents_delete", { slug: slugValue });
      await agents.refresh().catch(() => {});
      await tabs.close(tabId);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  function onKey(e: KeyboardEvent) {
    if ((e.key === "s" || e.key === "S") && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      void save();
    }
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="agent-doc" data-testid="agent-tab">
  <header class="bar">
    <span class="kicker">
      {#if isNew}New agent{:else if scope === "user"}Agent · workbook{:else}Agent · {scope} (read-only){/if}
    </span>
    <span class="spacer"></span>
    {#if status}<span class="ok"><CheckCircle weight="fill" size={13} /> {status}</span>{/if}
    {#if !isNew}
      <button
        type="button"
        class="ghost"
        class:active={isPinned}
        title={isPinned ? "Unpin as default" : "Pin as default"}
        onclick={togglePin}
        data-testid="agent-pin"
      >
        <Star weight="fill" size={13} /> {isPinned ? "Default" : "Pin default"}
      </button>
    {/if}
    {#if !isReadOnly}
      <button type="button" class="ghost" onclick={() => save()} disabled={busy} data-testid="agent-save">
        <Save weight="fill" size={13} /> {isNew ? "Create" : "Save"}
      </button>
      <button type="button" class="primary" onclick={publish} disabled={busy || publishing} data-testid="agent-publish">
        <Publish weight="fill" size={13} /> {publishing ? "Publishing…" : "Publish"}
      </button>
    {/if}
  </header>

  {#if !loaded}
    <div class="loading">Loading agent…</div>
  {:else}
    <div class="body">
      <!-- LEFT — settings -->
      <aside class="settings">
        <section class="hero">
          {#if isReadOnly}
            <AgentIconPicker value={icon} title={title} slug={slugValue} size={60} />
          {:else}
            <AgentIconPicker bind:value={icon} title={title} slug={slugValue} size={60} />
          {/if}
          <input class="title-input" placeholder="Agent name" bind:value={title} disabled={isReadOnly} data-testid="agent-title" />
          <input class="tagline-input" placeholder="One-line description" bind:value={tagline} disabled={isReadOnly} maxlength="160" />
        </section>

        <label class="field">
          <span class="lbl">Slug</span>
          <input class="mono" placeholder="my-agent" bind:value={slugValue}
            oninput={() => (slugManuallyEdited = true)}
            disabled={isReadOnly || !isNew} />
          {#if !isNew && !isReadOnly}<span class="help">Slug is locked once created.</span>{/if}
        </label>

        <div class="field">
          <span class="lbl">Model</span>
          <ModelPicker bind:value={model} placeholder="Inherit default LLM" />
        </div>

        <div class="field">
          <span class="lbl">Toolkits</span>
          {#if isReadOnly}
            <div class="chips-readonly">
              {#each packagesText.split(/\s+/).filter(Boolean) as p (p)}<span class="chip-static">{p}</span>{/each}
            </div>
          {:else}
            <ChipMultiSelect bind:value={packagesText} available={AVAILABLE_PACKAGES} placeholder="Add toolkit" />
          {/if}
          <span class="help">CLI binaries the agent calls via bash.</span>
        </div>

        <!-- Human-in-the-loop -->
        <div class="field hil">
          <button
            type="button"
            class="toggle"
            class:on={humanInLoop}
            role="switch"
            aria-checked={humanInLoop}
            onclick={() => { if (!isReadOnly) humanInLoop = !humanInLoop; }}
            disabled={isReadOnly}
            data-testid="agent-hil"
          >
            <span class="toggle-icon"><HumanLoop weight="fill" size={15} /></span>
            <span class="toggle-body">
              <span class="toggle-title">Human in the loop</span>
              <span class="toggle-meta">
                {humanInLoop
                  ? "Pauses for your approval before each action."
                  : "Runs autonomously without approval gates."}
              </span>
            </span>
            <span class="knob" aria-hidden="true"></span>
          </button>
        </div>

        {#if !isNew && scope === "user"}
          <button type="button" class="del" onclick={del} disabled={busy}>
            <Trash2 weight="fill" size={12} /> Delete agent
          </button>
        {/if}

        {#if error}<div class="error" data-testid="agent-error">{error}</div>{/if}
      </aside>

      <!-- RIGHT — system prompt -->
      <main class="prompt-pane">
        <div class="prompt-head">
          <span class="lbl">System prompt</span>
          <span class="lbl-aside">{systemPrompt.length} chars</span>
        </div>
        <textarea
          class="prompt"
          placeholder="Describe what the agent does. Lead with the job, then how it works, then any constraints."
          bind:value={systemPrompt}
          disabled={isReadOnly}
          data-testid="agent-prompt"
        ></textarea>
      </main>
    </div>
  {/if}
</div>

<style>
  .agent-doc {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    background: var(--color-page);
  }
  .bar {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 0.85rem;
    border-bottom: 1px solid var(--color-border);
    flex-shrink: 0;
    background: var(--color-surface);
  }
  .kicker {
    font-size: 0.68rem;
    text-transform: uppercase;
    letter-spacing: 0.1em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .spacer { flex: 1; }
  .ok {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    font-size: 0.78rem;
    color: var(--color-brand, #3fe081);
    font-weight: 600;
  }
  .loading {
    flex: 1 1 auto;
    display: grid;
    place-items: center;
    color: var(--color-fg-muted);
  }
  .body {
    flex: 1 1 auto;
    min-height: 0;
    display: grid;
    grid-template-columns: 380px 1fr;
    overflow: hidden;
  }
  .settings {
    overflow-y: auto;
    padding: 1.1rem 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
    border-right: 1px solid var(--color-border);
  }
  .hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.55rem;
  }
  .title-input, .tagline-input {
    width: 100%;
    text-align: center;
    background: transparent;
    border: 0;
    border-bottom: 1px solid transparent;
    color: var(--color-fg);
    padding: 0.2rem 0.4rem;
    outline: none;
    font: inherit;
  }
  .title-input { font-size: 1.1rem; font-weight: 600; }
  .tagline-input { font-size: 0.8rem; color: var(--color-fg-muted); }
  .title-input:hover:not(:disabled),
  .tagline-input:hover:not(:disabled) { border-bottom-color: var(--color-border); }
  .title-input:focus, .tagline-input:focus { border-bottom-color: var(--color-fg-subtle); }
  .field { display: flex; flex-direction: column; gap: 0.3rem; min-width: 0; }
  .lbl {
    font-size: 0.68rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .field input {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    padding: 0.45rem 0.6rem;
    outline: none;
  }
  .field input:focus { border-color: var(--color-fg-subtle); background: var(--color-surface); }
  .field input:disabled { opacity: 0.7; }
  .mono { font-family: ui-monospace, Menlo, monospace; font-size: 0.78rem; }
  .help { font-size: 0.7rem; color: var(--color-fg-muted); }
  .chips-readonly { display: flex; flex-wrap: wrap; gap: 0.3rem; }
  .chip-static {
    font-family: ui-monospace, Menlo, monospace;
    font-size: 0.72rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    padding: 0.15em 0.55em;
    border-radius: 4px;
  }
  /* Human-in-the-loop toggle */
  .hil { margin-top: 0.2rem; }
  .toggle {
    display: flex;
    align-items: center;
    gap: 0.65rem;
    width: 100%;
    text-align: left;
    padding: 0.7rem 0.8rem;
    border-radius: 9px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    cursor: pointer;
    font: inherit;
    transition: border-color 0.15s, background 0.15s;
  }
  .toggle:hover:not(:disabled) { border-color: var(--color-fg-subtle); }
  .toggle.on {
    border-color: color-mix(in srgb, var(--color-brand, #3fe081) 55%, transparent);
    background: color-mix(in srgb, var(--color-brand, #3fe081) 10%, var(--color-surface-soft));
  }
  .toggle:disabled { opacity: 0.6; cursor: not-allowed; }
  .toggle-icon {
    display: inline-flex;
    width: 30px; height: 30px;
    flex-shrink: 0;
    align-items: center;
    justify-content: center;
    border-radius: 7px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
  }
  .toggle.on .toggle-icon { color: var(--color-brand, #3fe081); }
  .toggle-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.1rem; }
  .toggle-title { font-size: 0.85rem; font-weight: 600; }
  .toggle-meta { font-size: 0.7rem; color: var(--color-fg-muted); }
  .knob {
    flex-shrink: 0;
    width: 34px; height: 20px;
    border-radius: 999px;
    background: var(--color-border);
    position: relative;
    transition: background 0.15s;
  }
  .knob::after {
    content: "";
    position: absolute;
    top: 2px; left: 2px;
    width: 16px; height: 16px;
    border-radius: 50%;
    background: #fff;
    transition: transform 0.15s;
  }
  .toggle.on .knob { background: var(--color-brand, #3fe081); }
  .toggle.on .knob::after { transform: translateX(14px); }
  .del {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    align-self: flex-start;
    padding: 0.35rem 0.7rem;
    border-radius: 6px;
    border: 1px solid rgba(252, 165, 165, 0.3);
    background: transparent;
    color: #fca5a5;
    font: inherit;
    font-size: 0.8rem;
    cursor: pointer;
  }
  .del:hover:not(:disabled) { background: rgba(252, 165, 165, 0.08); }
  .error {
    background: rgba(252, 165, 165, 0.12);
    border: 1px solid rgba(252, 165, 165, 0.35);
    color: #fca5a5;
    padding: 0.5rem 0.7rem;
    border-radius: 6px;
    font-size: 0.82rem;
  }
  .prompt-pane {
    display: flex;
    flex-direction: column;
    min-height: 0;
    padding: 1.1rem 1.25rem;
    background: var(--color-page);
  }
  .prompt-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-bottom: 0.4rem;
    flex-shrink: 0;
  }
  .lbl-aside { font-size: 0.65rem; color: var(--color-fg-muted); }
  .prompt {
    flex: 1 1 auto;
    min-height: 0;
    width: 100%;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    line-height: 1.55;
    padding: 0.8rem 1rem;
    outline: none;
    resize: none;
  }
  .prompt:focus { border-color: var(--color-fg-subtle); }
  .prompt:disabled { opacity: 0.8; }
  .ghost, .primary {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.35rem 0.75rem;
    border-radius: 6px;
    font: inherit;
    font-size: 0.78rem;
    font-weight: 600;
    cursor: pointer;
    border: 1px solid var(--color-border);
  }
  .ghost { background: transparent; color: var(--color-fg); }
  .ghost:hover:not(:disabled) { background: var(--color-surface-soft); }
  .ghost.active { color: var(--color-fg); border-color: var(--color-fg-subtle); }
  .primary {
    background: var(--color-brand, #3fe081);
    color: #06231a;
    border-color: transparent;
  }
  .primary:hover:not(:disabled) { filter: brightness(1.05); }
  .ghost:disabled, .primary:disabled { opacity: 0.5; cursor: not-allowed; }
</style>
