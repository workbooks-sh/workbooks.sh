<script lang="ts">
  /**
   * AgentScopesModal — informational modal showing what the active
   * agent CAN see and do. Pure read of parsed :agent: entity-binding
   * fields — model, tools, capabilities, spawn rules, system prompt
   * preview. Refers users to the agent's .org file for the full
   * source (link opens it as a doc tab).
   */
  import { X, FileText, Cpu, Wrench, Shield, ArrowRight } from "phosphor-svelte";
  import type { AgentCatalogEntry } from "$lib/bridge/agents.svelte";
  import { tabs } from "$lib/tabs/store.svelte";
  import AgentIcon from "./AgentIcon.svelte";

  let {
    agent,
    oncancel,
  }: {
    agent: AgentCatalogEntry;
    oncancel: () => void;
  } = $props();

  let cardEl: HTMLDivElement | undefined = $state();

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    oncancel();
  }
  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") oncancel();
  }

  function openSource() {
    tabs.open(agent.path);
    oncancel();
  }

  const scopeLabel: Record<string, string> = {
    project: "Project",
    user: "User",
    builtin: "Built-in",
  };
</script>

<svelte:window onkeydown={onKey} />

<div class="backdrop" onmousedown={backdrop} role="presentation">
  <div class="card" bind:this={cardEl}>
    <header class="head">
      <AgentIcon
        icon={agent.icon}
        title={agent.title}
        slug={agent.slug}
        size={32}
      />
      <div class="head-text">
        <div class="kicker">
          <span class="scope-chip">{scopeLabel[agent.scope] ?? agent.scope}</span>
          <span class="slug">{agent.slug}</span>
        </div>
        <h3>{agent.title ?? agent.slug}</h3>
      </div>
      <button
        type="button"
        class="icon-btn"
        title="Close"
        aria-label="Close"
        onclick={oncancel}
      >
        <X weight="bold" size={14} />
      </button>
    </header>

    <div class="body">
      {#if agent.parse_error}
        <section class="error-block">
          <strong>This agent's .org file failed to parse.</strong>
          <code>{agent.parse_error}</code>
        </section>
      {:else}
        <section class="prop-row">
          <Cpu weight="fill" size={13} aria-hidden="true" />
          <div>
            <div class="prop-label">Model</div>
            <div class="prop-value">
              {agent.model ?? "(default — uses WB_AGENT_MODEL)"}
            </div>
          </div>
        </section>

        {@const toolkits = agent.toolkits ?? agent.packages ?? []}
        <section class="prop-row">
          <Wrench weight="fill" size={13} aria-hidden="true" />
          <div>
            <div class="prop-label">
              Toolkits ({toolkits.length})
            </div>
            <div class="chips">
              {#if toolkits.length > 0}
                {#each toolkits as t (t)}
                  <span class="chip">{t}</span>
                {/each}
              {:else}
                <span class="muted">none declared</span>
              {/if}
            </div>
          </div>
        </section>

        {#if agent.tools && agent.tools.length > 0}
          <section class="prop-row">
            <Wrench weight="fill" size={13} aria-hidden="true" />
            <div>
              <div class="prop-label">
                Tools allowlist ({agent.tools.length})
              </div>
              <div class="chips">
                {#each agent.tools as t (t)}
                  <span class="chip">{t}</span>
                {/each}
              </div>
            </div>
          </section>
        {/if}

        <section class="prop-row">
          <Shield weight="fill" size={13} aria-hidden="true" />
          <div>
            <div class="prop-label">
              Capabilities ({agent.capabilities?.length ?? 0})
            </div>
            <div class="chips">
              {#if agent.capabilities && agent.capabilities.length > 0}
                {#each agent.capabilities as c (c)}
                  <span class="chip">{c}</span>
                {/each}
              {:else}
                <span class="muted">none</span>
              {/if}
            </div>
          </div>
        </section>

        {#if agent.allow_spawn || (agent.max_children ?? 0) > 0}
          <section class="prop-row">
            <ArrowRight weight="bold" size={13} aria-hidden="true" />
            <div>
              <div class="prop-label">Sub-agents</div>
              <div class="prop-value">
                Spawn {agent.allow_spawn ? "enabled" : "disabled"}
                · max children {agent.max_children ?? 0}
                · depth {agent.spawn_depth ?? 1}
                {#if agent.can_grant && agent.can_grant.length > 0}
                  · grants: {agent.can_grant.join(", ")}
                {/if}
              </div>
            </div>
          </section>
        {/if}

        {#if agent.system_prompt_preview}
          <section class="prompt">
            <div class="prop-label">System prompt</div>
            <p class="prompt-body">{agent.system_prompt_preview}</p>
          </section>
        {/if}
      {/if}
    </div>

    <footer class="foot">
      <button type="button" class="ghost" onclick={openSource}>
        <FileText weight="fill" size={12} />
        Open source
      </button>
      <button type="button" class="primary" onclick={oncancel}>Done</button>
    </footer>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.32);
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .card {
    width: min(560px, 92vw);
    max-height: 80vh;
    display: flex;
    flex-direction: column;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop, 0 12px 40px rgba(0, 0, 0, 0.35));
    overflow: hidden;
  }
  .head {
    display: flex;
    align-items: flex-start;
    gap: 0.5rem;
    padding: 0.85rem 1rem 0.7rem;
    border-bottom: 1px solid var(--color-border);
  }
  .head-text {
    flex: 1 1 auto;
    min-width: 0;
  }
  .kicker {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    margin-bottom: 0.2rem;
  }
  .scope-chip {
    display: inline-block;
    font-size: 0.65rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 0.1em 0.5em;
    border-radius: 999px;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    font-weight: 600;
  }
  .slug {
    font-size: 0.72rem;
    color: var(--color-fg-subtle);
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  h3 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
  }
  .icon-btn {
    background: transparent;
    border: 0;
    cursor: pointer;
    color: var(--color-fg-muted);
    padding: 0.2rem;
    border-radius: 4px;
  }
  .icon-btn:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .body {
    flex: 1 1 auto;
    overflow: auto;
    padding: 0.85rem 1rem;
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
  }
  .prop-row {
    display: flex;
    gap: 0.65rem;
    align-items: flex-start;
    color: var(--color-fg-muted);
  }
  .prop-row > div {
    flex: 1 1 auto;
    min-width: 0;
  }
  .prop-label {
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--color-fg-subtle);
    margin-bottom: 0.25rem;
    font-weight: 600;
  }
  .prop-value {
    color: var(--color-fg);
    font-size: 0.82rem;
  }
  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: 0.3rem;
  }
  .chip {
    display: inline-block;
    font-size: 0.72rem;
    padding: 0.12em 0.5em;
    border-radius: 4px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    border: 1px solid var(--color-border);
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .muted {
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    font-style: italic;
  }
  .prompt {
    border-top: 1px solid var(--color-border);
    padding-top: 0.7rem;
  }
  .prompt-body {
    margin: 0;
    color: var(--color-fg);
    font-size: 0.82rem;
    line-height: 1.45;
    white-space: pre-wrap;
  }
  .error-block {
    color: #fca5a5;
    font-size: 0.85rem;
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .error-block code {
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.8rem;
    background: var(--color-surface-soft);
    padding: 0.4rem 0.55rem;
    border-radius: 4px;
    border: 1px solid var(--color-border);
    word-break: break-all;
  }
  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 0.5rem;
    padding: 0.65rem 1rem;
    border-top: 1px solid var(--color-border);
    background: var(--color-page);
  }
  .ghost,
  .primary {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.35rem 0.75rem;
    border-radius: 6px;
    font-size: 0.82rem;
    font-weight: 500;
    cursor: pointer;
    border: 1px solid var(--color-border);
  }
  .ghost {
    background: transparent;
    color: var(--color-fg);
  }
  .ghost:hover {
    background: var(--color-surface-soft);
  }
  .primary {
    background: var(--color-primary-bg, var(--color-fg));
    color: var(--color-primary-fg, var(--color-page));
    border-color: transparent;
  }
</style>
