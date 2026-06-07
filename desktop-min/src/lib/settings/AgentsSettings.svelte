<script lang="ts">
  /**
   * AgentsSettings — catalog of agents as tight rows (icon + title +
   * tagline + pin-as-default). A default-LLM fallback picker sits at
   * the top; the pinned agent floats first. Mirrors the old panel,
   * minus the full editor wizard (deferred with the backend).
   */
  import { onMount } from "svelte";
  import { Bot, Star } from "@lucide/svelte";
  import { commands, type AgentCatalogEntry, type AgentSettings } from "$lib/bindings";
  import SettingsPanel from "./SettingsPanel.svelte";

  let agents = $state<AgentCatalogEntry[]>([]);
  let settings = $state<AgentSettings | null>(null);

  onMount(async () => {
    [agents, settings] = await Promise.all([commands.agentsList(), commands.agentSettingsGet()]);
  });

  const rows = $derived(
    [...agents].sort((a, b) => {
      const pin = settings?.defaultAgentSlug;
      if (a.slug === pin) return -1;
      if (b.slug === pin) return 1;
      return a.title.localeCompare(b.title);
    }),
  );

  async function togglePin(a: AgentCatalogEntry) {
    const next = settings?.defaultAgentSlug === a.slug ? "" : a.slug;
    settings = await commands.agentSettingsSet({ defaultAgentSlug: next });
  }

  async function onModel(e: Event) {
    const v = (e.currentTarget as HTMLInputElement).value;
    settings = await commands.agentSettingsSet({ defaultModel: v });
  }
</script>

<SettingsPanel title="Agents" lede="Your agent catalog. Pin one as the default and set the LLM that agents fall back to.">
  <label class="llm">
    <span class="lbl">Default LLM</span>
    <input
      type="text"
      value={settings?.defaultModel ?? ""}
      placeholder="Falls back to env"
      onchange={onModel}
    />
  </label>

  <ul class="list">
    {#each rows as a (a.slug)}
      {@const pinned = a.slug === settings?.defaultAgentSlug}
      <li class="row">
        <span class="ico"><Bot size={15} strokeWidth={1.8} /></span>
        <span class="body">
          <span class="title">
            {a.title}
            {#if pinned}<span class="chip">default</span>{/if}
            {#if a.parseError}<span class="chip err">parse error</span>{/if}
          </span>
          <span class="meta">
            {#if a.tagline}{a.tagline}{:else if a.model}<code>{a.model}</code>{:else}<em>uses default LLM</em>{/if}
          </span>
        </span>
        <button
          class="star"
          class:on={pinned}
          title={pinned ? "Unpin default" : "Pin as default"}
          aria-label={pinned ? "Unpin default" : "Pin as default"}
          onclick={() => togglePin(a)}
        >
          <Star size={13} strokeWidth={1.8} fill={pinned ? "currentColor" : "none"} />
        </button>
      </li>
    {/each}
  </ul>
</SettingsPanel>

<style>
  .llm {
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }
  .llm .lbl {
    font-size: 0.8rem;
    font-weight: 500;
    color: var(--color-fg-muted);
  }
  .llm input {
    flex: 1;
    min-width: 0;
    height: 30px;
    padding: 0 0.55rem;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.8rem;
  }
  .llm input:focus {
    outline: none;
    border-color: var(--color-border-strong);
  }
  .list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.45rem 0.5rem;
    border: 1px solid transparent;
    border-radius: 8px;
  }
  .row:hover {
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .ico {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    flex-shrink: 0;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
  }
  .body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.05rem;
  }
  .title {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.84rem;
    font-weight: 600;
  }
  .meta {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .meta code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  .chip {
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-weight: 600;
    padding: 0.1em 0.45em;
    border-radius: 3px;
    background: var(--color-fg);
    color: var(--color-page);
  }
  .chip.err {
    background: color-mix(in srgb, var(--color-err) 18%, transparent);
    color: var(--color-err);
  }
  .star {
    flex-shrink: 0;
    padding: 0.3rem;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
  }
  .star:hover {
    background: var(--color-border);
    color: var(--color-fg);
  }
  .star.on {
    color: var(--color-fg);
  }
</style>
