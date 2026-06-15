<script lang="ts">
  /**
   * Component-toolkit artifact card — the in-chat affordance for an
   * artifact the agent produced via the component EXEC shape. The tab
   * auto-opens; this card is the persistent handle to re-open / focus it
   * and the visible record that the agent built something.
   */
  import { FileHtml, ArrowSquareOut, Sparkle } from "phosphor-svelte";
  import { componentArtifacts } from "./artifacts.svelte";

  let {
    path,
    title,
    action,
  }: { path: string; title: string; action: "created" | "updated" } = $props();
</script>

<button
  type="button"
  class="artifact"
  onclick={() => componentArtifacts.open(path)}
  title="Open {title} as a tab"
>
  <span class="thumb"><FileHtml size={20} weight="fill" /></span>
  <span class="meta">
    <span class="verb">
      <Sparkle size={11} weight="fill" />
      {action === "updated" ? "Updated component" : "Component built"}
    </span>
    <span class="title">{title}</span>
    <span class="path">{path}</span>
  </span>
  <span class="open"><ArrowSquareOut size={15} weight="bold" /> Open</span>
</button>

<style>
  .artifact {
    display: flex;
    align-items: center;
    gap: 11px;
    width: 100%;
    max-width: 360px;
    padding: 10px 12px;
    border: 1px solid color-mix(in srgb, var(--color-brand) 30%, var(--color-border));
    border-radius: 12px;
    background: color-mix(in srgb, var(--color-brand) 7%, var(--color-surface));
    color: var(--color-fg);
    text-align: left;
    cursor: pointer;
    transition: border-color 0.14s, background 0.14s, transform 0.08s;
  }
  .artifact:hover {
    border-color: var(--color-brand);
    background: color-mix(in srgb, var(--color-brand) 12%, var(--color-surface));
  }
  .artifact:active {
    transform: translateY(1px);
  }
  .thumb {
    flex-shrink: 0;
    display: grid;
    place-items: center;
    width: 38px;
    height: 38px;
    border-radius: 9px;
    background: color-mix(in srgb, var(--color-brand) 18%, transparent);
    color: var(--color-brand);
  }
  .meta {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .verb {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font: 600 9.5px/1 var(--font-mono), ui-monospace, monospace;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--color-brand);
  }
  .title {
    font-size: 0.86rem;
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .path {
    font: 10.5px/1.3 var(--font-mono), ui-monospace, monospace;
    color: var(--color-fg-subtle);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .open {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 5px 9px;
    border-radius: 8px;
    background: var(--color-brand);
    color: var(--color-page);
    font-size: 0.75rem;
    font-weight: 600;
  }
</style>
