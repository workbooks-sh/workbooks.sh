<script lang="ts">
  /**
   * Renders an assistant message body — Markdown (default) or org with
   * inline components when the message opts in via `#+RENDER: org`.
   *
   * Default (plain) path: the model writes Markdown, so we render it as
   * Markdown — bold, italic, lists, headings, inline code, links —
   * SANITIZED (HTML-escaped first; see ./markdown.ts). This replaces the
   * old `{text}` literal which showed raw `**bold**` / `- bullets`.
   *
   * Org prose is rendered by the EXISTING $lib/org-renderer OQL-WASM
   * pipeline (renderOrg) — no second parser. Component blocks mount the REAL
   * <work-gen-block> SDK element (workponents ai domain) via WorkGenBlock —
   * the Svelte twin (ChatComponent.svelte) is retired. Same syntax, same
   * structured-prop safety; one shipped implementation, themed via the
   * --work-* bridge. Interactive blocks fire `work-intent` (bubbles+composed)
   * which the chat container forwards back into the session.
   *
   * See desktop/docs/waldo-inchat-components.md.
   */
  import { renderMode, splitOrg, type Segment } from "./messageRender";
  import { renderMarkdown } from "./markdown";
  import { renderOrg } from "$lib/org-renderer/render";
  import WorkGenBlock from "./WorkGenBlock.svelte";
  import "$lib/org-renderer/org.css";

  let { text }: { text: string } = $props();

  const mode = $derived(renderMode(text));
  const segments = $derived<Segment[]>(mode === "org" ? splitOrg(text) : []);
  // Sanitized Markdown HTML for the plain path (computed only when plain).
  const md = $derived(mode === "plain" ? renderMarkdown(text) : "");

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
  <!-- Sanitized Markdown — md is built from HTML-escaped source, so the
       only tags present are this renderer's own fixed safe set. -->
  <div class="agent-text agent-md">{@html md}</div>
{:else}
  <div class="agent-org">
    {#each segments as seg, i (i)}
      {#if seg.kind === "org"}
        {#await org(seg.source) then html}
          <div class="org-doc"><div class="org-content">{@html html}</div></div>
        {/await}
      {:else}
        <WorkGenBlock type={seg.type} props={seg.props} body={seg.body} />
      {/if}
    {/each}
  </div>
{/if}

<style>
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
