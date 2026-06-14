<script lang="ts">
  /**
   * Renders an assistant message body — plain text (default) or org
   * with inline components when the message opts in via `#+RENDER: org`.
   *
   * Org prose is rendered by the EXISTING $lib/org-renderer OQL-WASM
   * pipeline (renderOrg) — no second parser. Component blocks are
   * dispatched to ChatComponent. Plain mode is byte-for-byte the old
   * `<div class="agent-text">{text}</div>`, so nothing regresses.
   *
   * See desktop/docs/waldo-inchat-components.md.
   */
  import { renderMode, splitOrg, type Segment } from "./messageRender";
  import { renderOrg } from "$lib/org-renderer/render";
  import ChatComponent from "./ChatComponent.svelte";
  import "$lib/org-renderer/org.css";

  let { text }: { text: string } = $props();

  const mode = $derived(renderMode(text));
  const segments = $derived<Segment[]>(mode === "org" ? splitOrg(text) : []);

  // Cache org→HTML so re-renders (e.g. sibling reactivity) don't re-run
  // the WASM call for unchanged source.
  const htmlCache = new Map<string, string>();
  async function org(source: string): Promise<string> {
    const hit = htmlCache.get(source);
    if (hit !== undefined) return hit;
    const html = await renderOrg(source);
    htmlCache.set(source, html);
    return html;
  }
</script>

{#if mode === "plain"}
  <div class="agent-text">{text}</div>
{:else}
  <div class="agent-org">
    {#each segments as seg, i (i)}
      {#if seg.kind === "org"}
        {#await org(seg.source) then html}
          <div class="org-doc"><div class="org-content">{@html html}</div></div>
        {/await}
      {:else}
        <ChatComponent type={seg.type} props={seg.props} body={seg.body} />
      {/if}
    {/each}
  </div>
{/if}

<style>
  .agent-text {
    color: var(--color-fg);
  }
  .agent-org {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    color: var(--color-fg);
  }
  /* Tighten the shared org.css for the chat surface: the full-doc
     padding/max-width is for the viewer, not a chat bubble. */
  .agent-org :global(.org-doc) {
    padding: 0;
    max-width: none;
    font-size: 13.5px;
    line-height: 1.55;
  }
  .agent-org :global(.org-content > main) {
    margin: 0;
  }
</style>
