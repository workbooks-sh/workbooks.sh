<script lang="ts">
  /**
   * Renders an assistant message body: Markdown prose + inline `<work-*>`
   * components, in order.
   *
   * The model writes Markdown (bold, italic, lists, headings, inline code,
   * links), rendered SANITIZED (HTML-escaped first; see ./markdown.ts), and
   * emits components as inline `<work-tag attr="v">body</work-tag>` HTML.
   * splitComponents() separates the two; each `<work-*>` mounts the REAL SDK
   * custom element via WorkElement (structured attrs + textContent, never
   * `{@html}` of raw model output). Interactive elements fire `work-intent`
   * (bubbles + composed), which the chat container forwards into the session.
   */
  import { splitComponents, type Segment } from "./messageRender";
  import { renderMarkdown } from "./markdown";
  import WorkElement from "./WorkElement.svelte";

  let { text }: { text: string } = $props();

  const segments = $derived<Segment[]>(splitComponents(text));
</script>

<div class="agent-msg">
  {#each segments as seg, i (i)}
    {#if seg.kind === "text"}
      <!-- Sanitized Markdown — built from HTML-escaped source, so the only
           tags present are this renderer's own fixed safe set. -->
      <div class="agent-text agent-md">{@html renderMarkdown(seg.source)}</div>
    {:else}
      <WorkElement tag={seg.tag} attrs={seg.attrs} body={seg.body} />
    {/if}
  {/each}
</div>

<style>
  .agent-msg {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  .agent-text {
    color: var(--color-fg);
  }
  /* Rendered Markdown — tight, chat-bubble-scale rhythm. First/last
     block margins collapse so a bubble doesn't grow extra padding. */
  .agent-md :global(p) {
    margin: 0 0 0.5em;
  }
  .agent-md :global(*:first-child) { margin-top: 0; }
  .agent-md :global(*:last-child) { margin-bottom: 0; }
  .agent-md :global(strong) { font-weight: 650; }
  .agent-md :global(em) { font-style: italic; }
  .agent-md :global(h1),
  .agent-md :global(h2),
  .agent-md :global(h3) {
    margin: 0.6em 0 0.35em;
    line-height: 1.3;
    font-weight: 650;
  }
  .agent-md :global(h1) { font-size: 1.18em; }
  .agent-md :global(h2) { font-size: 1.1em; }
  .agent-md :global(h3) { font-size: 1.02em; }
  .agent-md :global(ul),
  .agent-md :global(ol) {
    margin: 0.25em 0 0.5em;
    padding-left: 1.35em;
  }
  .agent-md :global(li) { margin: 0.15em 0; }
  .agent-md :global(li::marker) { color: var(--color-fg-muted); }
  .agent-md :global(code) {
    font-family: var(--font-mono);
    font-size: 0.88em;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 4px;
    padding: 0.05em 0.3em;
  }
  .agent-md :global(pre) {
    margin: 0.4em 0 0.55em;
    padding: 0.6em 0.75em;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    overflow-x: auto;
  }
  .agent-md :global(pre code) {
    background: none;
    border: 0;
    padding: 0;
    font-size: 0.85em;
  }
  .agent-md :global(a) {
    color: var(--color-brand);
    text-decoration: underline;
    text-underline-offset: 2px;
  }
</style>
