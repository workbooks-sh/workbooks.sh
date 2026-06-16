<script lang="ts">
  /**
   * AgentEditor — single editor surface for both creating a new agent
   * and editing an existing user-scope one. Replaces:
   *   - the previous CreateAgentDialog "from template" path
   *   - the inline raw-org textarea inside AgentsSettings rows
   *
   * Design: one focused column, big icon tile up top (the clickable
   * AgentIconPicker), then title → identity → behavior. System prompt
   * is the biggest interactive surface — that's where authoring
   * actually happens. Tools + Capabilities are comma-separated text
   * inputs with placeholder help; advanced spawn knobs aren't in v1
   * (hand-edit the .org for those).
   *
   * Built-in / project-scope agents open in READ-ONLY mode (no save).
   * User-scope: full create + update + delete.
   */
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { X, Trash as Trash2, FloppyDisk as Save } from "phosphor-svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { agents, type AgentCatalogEntry } from "$lib/bridge/agents.svelte";
  import { agentSessions } from "./agent_sessions.svelte";
  import AgentIconPicker from "./AgentIconPicker.svelte";
  import ModelPicker from "./ModelPicker.svelte";
  import ChipMultiSelect from "./ChipMultiSelect.svelte";
  import AgentIcon from "./AgentIcon.svelte";

  // Curated toolkit list — CLI binaries an agent can declare on its
  // `:TOOLKITS:` line (wb-1nbj; pre-rename was `:PACKAGES:`).
  // Group order matches the picker's section order (repo-shipped
  // first, then external integrations). Authors can still add
  // custom values via the chip picker's allowCustom path.
  const AVAILABLE_PACKAGES = [
    // Repo-shipped:
    "bash",        // executor
    "wb",          // Workbooks CLI — query / memory / agent / tab / fs / …
    "lua",         // luerl-backed Lua executor
    "wavelet",     // motion-graphics renderer
    "brandnana",   // brand intelligence
    // External / system:
    "git", "cargo", "npm", "pnpm", "node",
    // External integrations (provisioned via Settings → Packages,
    // binary lands on PATH after key configuration):
    "gws", "claude", "codex", "composio", "doppler", "fal",
  ];

  let {
    /** Slug to edit. `null` = create-new mode. */
    slug = null,
    oncancel,
    onsaved,
  }: {
    slug?: string | null;
    oncancel: () => void;
    onsaved: (slug: string) => void;
  } = $props();

  // Editor state. Initialized in onMount (existing slug) or defaults
  // (new agent).
  let title = $state("");
  let tagline = $state("");
  let slugValue = $state("");
  let model = $state("xiaomi/mimo-v2.5-pro");
  let icon = $state("");
  let systemPrompt = $state("");
  // Space-separated string of toolkit names — the on-disk format
  // for the :TOOLKITS: drawer property. ChipMultiSelect binds to it.
  let packagesText = $state("");

  // For edit mode: the exact source bytes we loaded. Save patches
  // THIS string (not a from-scratch rebuild) so unknown properties,
  // #+EXTENSIONS, nested sub-headings under ** System prompt, and
  // comments all round-trip intact.
  let originalSource = $state<string | null>(null);

  let scope = $state<"user" | "project" | "builtin" | null>(null);
  let busy = $state(false);
  let error = $state<string | null>(null);
  let slugManuallyEdited = $state(false);

  const isNew = $derived(slug === null);
  const isReadOnly = $derived(scope === "builtin" || scope === "project");

  let cardEl: HTMLDivElement | undefined = $state();

  onMount(() => {
    void load();
  });

  async function load() {
    if (slug === null) {
      // New agent — defaults.
      title = "New agent";
      tagline = "";
      slugValue = "";
      icon = "";
      systemPrompt = "";
      packagesText = "bash wb";
      scope = "user";
      originalSource = null;
      return;
    }
    error = null;
    try {
      const entry = agents.agents.find((a) => a.slug === slug);
      if (!entry) {
        error = `Agent '${slug}' not in catalog.`;
        return;
      }
      scope = entry.scope;
      title = entry.title ?? entry.slug;
      tagline = entry.tagline ?? "";
      slugValue = entry.slug;
      icon = entry.icon ?? "";
      model = entry.model ?? "xiaomi/mimo-v2.5-pro";
      // Backend now surfaces `toolkits` from `:TOOLKITS:` (preferred)
      // or legacy `:PACKAGES:` (with a daemon-side warning).
      // `packages` is the transitional alias for the same value;
      // fall back through both for daemons on older builds.
      packagesText = (
        entry.toolkits ?? entry.packages ?? []
      ).join(" ");

      // For user-scope we read the full source so save can patch it
      // verbatim (preserving unknown properties + sub-headings under
      // ** System prompt). For built-in / project we only have the
      // preview from the catalog enrichment.
      if (entry.scope === "user") {
        try {
          const file = await invoke<{ source: string }>("agents_read", {
            slug: entry.slug,
          });
          originalSource = file.source;
          systemPrompt = extractSystemPrompt(file.source);
        } catch (e) {
          originalSource = null;
          systemPrompt = entry.system_prompt_preview ?? "";
        }
      } else {
        originalSource = null;
        systemPrompt = entry.system_prompt_preview ?? "";
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  /** Capture the body of the `** System prompt` subsection up to EOF
   *  or the next sibling level-1/level-2 heading. Verbatim — no
   *  trim — so an untouched textarea round-trips byte-for-byte
   *  through save.
   *
   *  No `m` flag — under multiline mode `(?=$)` matches end of every
   *  line, which collapsed the lazy capture to a single line. With
   *  default mode, `$` matches end of input. We negate on `*[^*]`
   *  rather than `*\s` so single-star headings (level-1) trip the
   *  end but level-3 (`*** ...`) sub-headings under the prompt body
   *  do not. */
  function extractSystemPrompt(src: string): string {
    const m = src.match(
      /\*\*\s+System prompt\s*\n([\s\S]*?)(?=\n\*\*[^*]|\n\*[^*]|$)/,
    );
    return m ? m[1] : "";
  }

  // ── Non-destructive source patching ───────────────────────────────

  /** Replace `:NAME: <oldval>` with `<newval>`. Inserts before
   *  `:END:` when the property is missing. Removes the line when
   *  newval is empty. */
  function setProperty(src: string, name: string, value: string): string {
    const trimmed = value.trim();
    const lineRe = new RegExp(`^(\\s*:${name}:)\\s+([^\\n]*)$`, "m");
    const existing = src.match(lineRe);
    if (existing) {
      if (existing[2].trim() === trimmed) return src;
      if (!trimmed) {
        return src.replace(
          new RegExp(`^\\s*:${name}:\\s+[^\\n]*\\n`, "m"),
          "",
        );
      }
      // Preserve the column alignment of the existing line as best we
      // can — match the trailing whitespace before the old value.
      return src.replace(
        lineRe,
        (_m, key) => `${key.padEnd(15)}${trimmed}`,
      );
    }
    if (!trimmed) return src;
    // Insert before :END:.
    return src.replace(
      /^(\s*):END:/m,
      (_m, indent) =>
        `${indent}:${name}:`.padEnd(`${indent}:${name}:`.length + 11) +
        `${trimmed}\n${indent}:END:`,
    );
  }

  /** Replace the agent headline's title text (the part between
   *  the `* ` and the trailing `:agent:` tag). */
  function setTitle(src: string, newTitle: string): string {
    return src.replace(
      /^(\*\s+)([^\n]+?)(\s*(?::[a-zA-Z_][\w-]*:)+\s*)$/m,
      (_m, prefix, _old, tags) =>
        `${prefix}${newTitle.trim() || "Untitled"}${tags ?? ""}`,
    );
  }

  /** Replace the body of `** System prompt` with `body`. Same regex
   *  shape as `extractSystemPrompt` — no `m` flag, end on a real
   *  sibling heading (not on every newline). */
  function setSystemPrompt(src: string, body: string): string {
    const re = /(\*\*\s+System prompt\s*\n)([\s\S]*?)(?=\n\*\*[^*]|\n\*[^*]|$)/;
    if (re.test(src)) {
      return src.replace(re, `$1${body}`);
    }
    return src.replace(/\n*$/, `\n\n** System prompt\n${body}\n`);
  }

  /** Ensure `#+EXTENSIONS:` includes `key`. Adds the keyword if the
   *  file has none. */
  function ensureExtension(src: string, key: string): string {
    if (new RegExp(`^#\\+EXTENSIONS:.*\\b${key}\\b`, "m").test(src)) {
      return src;
    }
    if (/^#\+EXTENSIONS:/m.test(src)) {
      return src.replace(
        /^(#\+EXTENSIONS:[^\n]*)$/m,
        (_m, line) => `${line} ${key}`,
      );
    }
    return `#+EXTENSIONS: ${key}\n\n${src}`;
  }

  // Auto-derive slug from title in new mode until user types in the
  // slug field directly.
  $effect(() => {
    if (!isNew || slugManuallyEdited) return;
    slugValue = title
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .replace(/-{2,}/g, "-");
  });

  function buildOrgFromScratch(): string {
    const pkgs = packagesText.split(/\s+/).filter(Boolean).join(" ");
    const hasIcon = icon.trim().length > 0;
    const hasTagline = tagline.trim().length > 0;
    const hasToolkits = pkgs.length > 0;
    const extra: string[] = [];
    if (hasIcon) extra.push("ICON");
    if (hasTagline) extra.push("TAGLINE");
    if (hasToolkits) extra.push("TOOLKITS");
    const extensions = extra.length > 0
      ? `#+EXTENSIONS: ${extra.join(" ")}\n\n`
      : "";

    const lines: string[] = [];
    lines.push(
      `* ${title.trim() || slugValue}                                                          :agent:`,
    );
    lines.push(`  :PROPERTIES:`);
    lines.push(`  :ID:           ${slugValue}`);
    lines.push(`  :TYPE:         ai`);
    if (model.trim()) lines.push(`  :MODEL:        ${model.trim()}`);
    if (hasIcon) lines.push(`  :ICON:         ${icon.trim()}`);
    if (tagline.trim()) lines.push(`  :TAGLINE:      ${tagline.trim()}`);
    if (hasToolkits) lines.push(`  :TOOLKITS:     ${pkgs}`);
    lines.push(`  :END:`);
    if (systemPrompt.trim()) {
      lines.push(`** System prompt`);
      lines.push(systemPrompt.trim());
    }
    return extensions + lines.join("\n") + "\n";
  }

  /** Patch the loaded source byte-for-byte, mutating only the
   *  fields the editor surfaces. Unknown drawer properties
   *  (ALLOW_SPAWN, SPAWN_DEPTH, MAX_CHILDREN, CAN_GRANT, anything a
   *  plugin-author adds), file-level keywords other than
   *  #+EXTENSIONS, and any structure under ** System prompt the
   *  user didn't touch all survive intact. */
  function patchOrg(src: string): string {
    let out = src;
    out = setTitle(out, title);
    out = setProperty(out, "MODEL", model);
    out = setProperty(out, "ICON", icon);
    out = setProperty(out, "TOOLKITS", packagesText);
    // Drop the retired :PACKAGES: alias on save so the file's
    // source-of-truth moves to :TOOLKITS: cleanly (wb-1nbj). The
    // engine still reads :PACKAGES: as a legacy fallback with a
    // one-time warning, so older files keep working.
    out = setProperty(out, "PACKAGES", "");
    out = setSystemPrompt(out, systemPrompt);
    if (icon.trim()) out = ensureExtension(out, "ICON");
    return out;
  }

  async function save() {
    if (isReadOnly || busy) return;
    error = null;
    if (!slugValue.trim()) {
      error = "Slug cannot be empty.";
      return;
    }
    busy = true;
    try {
      if (isNew) {
        // New agent — build from scratch; no source to patch over.
        const source = buildOrgFromScratch();
        await invoke("agents_create", {
          req: { slug: slugValue, source },
        });
      } else {
        // Existing agent — parser-backed property mutations via
        // the runtime's Document::set_property; title + body via
        // string splices over the parser-serialized output (until
        // wb-shtl.6 lands set_section_body / set_title). NO regex
        // over the raw file.
        const properties: Record<string, string> = {
          MODEL: model.trim(),
          ICON: icon.trim(),
          TAGLINE: tagline.trim(),
          TOOLKITS: packagesText.trim(),
          // Clear the retired :PACKAGES: alias on save (wb-1nbj).
          PACKAGES: "",
        };
        const result = await invoke<{ source: string }>("agents_patch", {
          req: {
            slug: slugValue,
            properties,
            title: title.trim() ? title.trim() : null,
            system_prompt: systemPrompt,
          },
        });
        originalSource = result.source;
      }
      await agents.refresh();
      onsaved(slugValue);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  async function del() {
    if (isNew || scope !== "user") return;
    if (!(await tauriConfirm(`Delete agent "${slugValue}"? This cannot be undone.`, { kind: "warning" }))) return;
    busy = true;
    error = null;
    try {
      await invoke("agents_delete", { slug: slugValue });
      agentSessions.clearAgent(slugValue);
      await agents.refresh();
      oncancel();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    oncancel();
  }
  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") oncancel();
    if ((e.key === "s" || e.key === "S") && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      void save();
    }
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="backdrop" onmousedown={backdrop} role="presentation">
  <div class="card" bind:this={cardEl} role="dialog" aria-modal="true">
    <header class="head">
      <span class="kicker">
        {#if isNew}New agent{:else if scope === "user"}Edit agent{:else}View agent · {scope}{/if}
      </span>
      <button
        type="button"
        class="close"
        aria-label="Close"
        title="Close (Esc)"
        onclick={oncancel}
      >
        <X weight="bold" size={14} />
      </button>
    </header>

    <div class="body">
      <!-- LEFT — metadata column -->
      <div class="left">
        <section class="hero">
          {#if isReadOnly}
            <div class="hero-icon-readonly" aria-hidden="true">
              <AgentIcon icon={icon} title={title} slug={slugValue} size={56} />
            </div>
          {:else}
            <AgentIconPicker
              bind:value={icon}
              title={title}
              slug={slugValue}
              size={56}
            />
          {/if}
          <input
            type="text"
            class="title-input"
            placeholder="Agent name"
            bind:value={title}
            disabled={isReadOnly}
          />
          <input
            type="text"
            class="tagline-input"
            placeholder="One-line description"
            bind:value={tagline}
            disabled={isReadOnly}
            maxlength="160"
          />
        </section>

        <label class="field">
          <span class="lbl">Slug</span>
          <input
            type="text"
            class="mono"
            placeholder="my-agent"
            bind:value={slugValue}
            oninput={() => (slugManuallyEdited = true)}
            disabled={isReadOnly || !isNew}
          />
          {#if !isNew && !isReadOnly}
            <span class="help">Slug is locked once created.</span>
          {/if}
        </label>

        <div class="field">
          <span class="lbl">Model</span>
          <ModelPicker bind:value={model} placeholder="Inherit default LLM" />
        </div>

        <div class="field">
          <span class="lbl">Toolkits</span>
          {#if isReadOnly}
            <div class="chips-readonly">
              {#each packagesText.split(/\s+/).filter(Boolean) as p (p)}
                <span class="chip-static">{p}</span>
              {/each}
            </div>
          {:else}
            <ChipMultiSelect
              bind:value={packagesText}
              available={AVAILABLE_PACKAGES}
              placeholder="Add toolkit"
            />
          {/if}
          <span class="help">
            CLI binaries the agent calls via bash. Skills tell it which
            commands to run for each task.
          </span>
        </div>

        {#if error}
          <div class="error">{error}</div>
        {/if}
      </div>

      <!-- RIGHT — system prompt canvas -->
      <div class="right">
        <div class="prompt-head">
          <span class="lbl">System prompt</span>
          <span class="lbl-aside">{systemPrompt.length} chars</span>
        </div>
        <textarea
          class="prompt"
          placeholder="Describe what the agent does. Lead with the job, then how it works, then any constraints. Keep it focused — under 200 words is usually right."
          bind:value={systemPrompt}
          disabled={isReadOnly}
        ></textarea>
      </div>
    </div>

    <footer class="foot">
      {#if !isNew && scope === "user"}
        <button
          type="button"
          class="ghost danger"
          onclick={del}
          disabled={busy}
        >
          <Trash2 weight="fill" size={12} />
          Delete
        </button>
      {/if}
      <span class="foot-spacer"></span>
      <button type="button" class="ghost" onclick={oncancel} disabled={busy}>
        {isReadOnly ? "Close" : "Cancel"}
      </button>
      {#if !isReadOnly}
        <button type="button" class="primary" onclick={save} disabled={busy}>
          <Save weight="fill" size={12} />
          {isNew ? "Create" : "Save"}
        </button>
      {/if}
    </footer>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.4);
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }
  .card {
    width: min(1100px, 100%);
    height: min(720px, 90vh);
    display: flex;
    flex-direction: column;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: 0 20px 50px rgba(0, 0, 0, 0.45);
    overflow: hidden;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 0.5rem 0.5rem 1rem;
    border-bottom: 1px solid var(--color-border);
    flex-shrink: 0;
  }
  .kicker {
    flex: 1;
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.1em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .close {
    width: 26px;
    height: 26px;
    border: 0;
    background: transparent;
    border-radius: 5px;
    color: var(--color-fg-muted);
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .close:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .body {
    flex: 1 1 auto;
    min-height: 0;
    display: grid;
    grid-template-columns: 380px 1fr;
    overflow: hidden;
  }
  .left {
    overflow-y: auto;
    padding: 1.1rem 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
    border-right: 1px solid var(--color-border);
  }
  .right {
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
  .hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.6rem;
    padding-bottom: 0.3rem;
  }
  .hero-icon-readonly {
    width: 56px;
    height: 56px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .title-input,
  .tagline-input {
    width: 100%;
    max-width: 360px;
    text-align: center;
    background: transparent;
    border: 0;
    border-bottom: 1px solid transparent;
    color: var(--color-fg);
    padding: 0.25rem 0.5rem;
    outline: none;
  }
  .title-input {
    font-size: 1.15rem;
    font-weight: 600;
  }
  .tagline-input {
    font-size: 0.82rem;
    color: var(--color-fg-muted);
    margin-top: -0.1rem;
  }
  .title-input:hover:not(:disabled),
  .tagline-input:hover:not(:disabled) {
    border-bottom-color: var(--color-border);
  }
  .title-input:focus,
  .tagline-input:focus {
    border-bottom-color: var(--color-fg-subtle);
  }
  .title-input:disabled,
  .tagline-input:disabled {
    opacity: 0.85;
  }
  .chips-readonly {
    display: flex;
    flex-wrap: wrap;
    gap: 0.3rem;
  }
  .chip-static {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.72rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    padding: 0.15em 0.55em;
    border-radius: 4px;
  }
  .field {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
    min-width: 0;
  }
  .lbl {
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .lbl-row {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
  }
  .lbl-aside {
    font-size: 0.65rem;
    color: var(--color-fg-muted);
    font-weight: 500;
    text-transform: none;
    letter-spacing: 0;
  }
  .field input,
  .field textarea {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    padding: 0.45rem 0.6rem;
    outline: none;
  }
  .field input:focus,
  .field textarea:focus {
    border-color: var(--color-fg-subtle);
    background: var(--color-surface);
  }
  .field input:disabled,
  .field textarea:disabled {
    opacity: 0.7;
    cursor: not-allowed;
  }
  .field .mono {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.78rem;
  }
  .prompt {
    flex: 1 1 auto;
    min-height: 0;
    width: 100%;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    color: var(--color-fg);
    font-family: inherit;
    font-size: 0.85rem;
    line-height: 1.55;
    padding: 0.8rem 1rem;
    outline: none;
    resize: none;
  }
  .prompt:focus {
    border-color: var(--color-fg-subtle);
  }
  .prompt:disabled {
    opacity: 0.8;
  }
  .help {
    font-size: 0.7rem;
    color: var(--color-fg-muted);
  }
  .error {
    background: rgba(252, 165, 165, 0.12);
    border: 1px solid rgba(252, 165, 165, 0.35);
    color: #fca5a5;
    padding: 0.5rem 0.7rem;
    border-radius: 6px;
    font-size: 0.82rem;
  }
  .foot {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.65rem 1rem;
    border-top: 1px solid var(--color-border);
    background: var(--color-page);
    flex-shrink: 0;
  }
  .foot-spacer {
    flex: 1;
  }
  .ghost,
  .primary {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.4rem 0.85rem;
    border-radius: 6px;
    font: inherit;
    font-size: 0.82rem;
    font-weight: 500;
    cursor: pointer;
    border: 1px solid var(--color-border);
  }
  .ghost {
    background: transparent;
    color: var(--color-fg);
  }
  .ghost:hover:not(:disabled) {
    background: var(--color-surface-soft);
  }
  .ghost.danger {
    color: #fca5a5;
    border-color: rgba(252, 165, 165, 0.3);
  }
  .ghost.danger:hover:not(:disabled) {
    background: rgba(252, 165, 165, 0.08);
  }
  .primary {
    background: var(--color-primary-bg, var(--color-fg));
    color: var(--color-primary-fg, var(--color-page));
    border-color: transparent;
  }
  .primary:disabled,
  .ghost:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
</style>
