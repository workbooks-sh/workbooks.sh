<script lang="ts">
  /**
   * Compact tool-call card — a wrench, the tool name in mono, a status chip,
   * and an optional one-line summary of the call's arguments.
   */
  import { Wrench, CheckCircle, CircleNotch, XCircle } from "phosphor-svelte";

  let {
    toolName,
    args,
    status,
    pending,
  }: {
    toolName: string;
    args?: unknown;
    status: "ok" | "error" | null;
    pending: boolean;
  } = $props();

  // Pull a single readable hint out of the args (title / path / slug).
  const summary = $derived.by(() => {
    if (!args || typeof args !== "object") return null;
    const a = args as Record<string, unknown>;
    const v = a.title ?? a.path ?? a.slug ?? a.name;
    return typeof v === "string" && v ? v : null;
  });
</script>

<div class="tool" class:err={status === "error"}>
  <span class="icn"><Wrench size={14} weight="fill" /></span>
  <span class="name">{toolName}</span>
  {#if summary}<span class="sum">{summary}</span>{/if}
  <span class="chip" class:pending class:ok={status === "ok"} class:bad={status === "error"}>
    {#if pending}
      <span class="spin"><CircleNotch size={12} weight="bold" /></span> running
    {:else if status === "error"}
      <XCircle size={12} weight="fill" /> error
    {:else}
      <CheckCircle size={12} weight="fill" /> done
    {/if}
  </span>
</div>

<style>
  .tool {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    max-width: 420px;
    padding: 8px 11px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg, 12px);
    background: var(--color-surface);
  }
  .icn {
    display: grid;
    place-items: center;
    flex-shrink: 0;
    width: 24px;
    height: 24px;
    border-radius: 7px;
    background: var(--color-surface-soft);
    color: var(--color-fg-subtle);
  }
  .name {
    font: 600 0.8rem/1 var(--font-mono), ui-monospace, monospace;
    color: var(--color-fg);
    flex-shrink: 0;
  }
  .sum {
    flex: 1;
    min-width: 0;
    font-size: 0.76rem;
    color: var(--color-fg-subtle);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .chip {
    margin-left: auto;
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    border-radius: 999px;
    font: 600 0.68rem/1 var(--font-mono), ui-monospace, monospace;
    letter-spacing: 0.02em;
    background: var(--color-surface-soft);
    color: var(--color-fg-subtle);
  }
  .chip.ok {
    background: color-mix(in srgb, var(--color-ok, #13d943) 16%, transparent);
    color: var(--color-ok, #13d943);
  }
  .chip.bad {
    background: color-mix(in srgb, var(--color-err, #ef4444) 16%, transparent);
    color: var(--color-err, #ef4444);
  }
  .spin {
    display: inline-flex;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
