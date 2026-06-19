<script lang="ts">
  /**
   * The whole agent conversation, rendered premium-AI-chat style:
   * right-aligned user bubbles, left "Waldo" turns carrying a collapsible
   * reasoning block, clean Markdown, tool-call cards, and artifact openers.
   *
   * Centralizes what HomePanel / WaldoPanel used to render inline.
   */
  import type { ChatBlock } from "./types";
  import AssistantMessageView from "./AssistantMessageView.svelte";
  import ArtifactCard from "./ArtifactCard.svelte";
  import Reasoning from "./elements/Reasoning.svelte";
  import ToolCall from "./elements/ToolCall.svelte";

  let {
    userLines,
    blocks,
    thinking = false,
  }: {
    userLines: { text: string; ts: number }[];
    blocks: ChatBlock[];
    thinking?: boolean;
  } = $props();

  type Row =
    | { kind: "user"; ts: number; key: string; text: string }
    | { kind: "block"; ts: number; key: string; block: ChatBlock };

  const rows = $derived.by<Row[]>(() => {
    const mine: Row[] = userLines.map((m, i) => ({
      kind: "user",
      ts: m.ts,
      key: `u-${i}-${m.ts}`,
      text: m.text,
    }));
    const theirs: Row[] = blocks
      // RawEventRows are debug-only — never shown.
      .filter((b) => b.kind !== "raw")
      // Drop "info" status banners (session-started chatter); keep terminal ones.
      .filter((b) => !(b.kind === "status" && b.level === "info"))
      .map((b) => ({ kind: "block", ts: b.ts, key: b.key, block: b }) as Row);
    return [...mine, ...theirs].sort((a, b) => a.ts - b.ts);
  });
</script>

<div class="thread-rows">
  {#each rows as row (row.key)}
    {#if row.kind === "user"}
      <div class="row user"><div class="ubub">{row.text}</div></div>
    {:else if row.block.kind === "message"}
      {@const m = row.block}
      <div class="row waldo">
        {#if m.reasoning}
          <Reasoning text={m.reasoning} streaming={m.pending} />
        {/if}
        {#if m.text}
          <div class="msg" class:err={m.error}>
            <AssistantMessageView text={m.text} />
          </div>
        {:else if m.pending}
          <span class="typing"><span></span><span></span><span></span></span>
        {/if}
      </div>
    {:else if row.block.kind === "tool"}
      {@const t = row.block}
      <div class="row waldo">
        <ToolCall toolName={t.toolName} args={t.args} status={t.status} pending={t.pending} />
      </div>
    {:else if row.block.kind === "artifact"}
      {@const a = row.block}
      <div class="row waldo">
        <ArtifactCard path={a.path} title={a.title} action={a.action} />
      </div>
    {:else if row.block.kind === "status"}
      <div class="status-line">{row.block.label}</div>
    {/if}
  {/each}
  {#if thinking}
    <div class="row waldo">
      <span class="typing"><span></span><span></span><span></span></span>
    </div>
  {/if}
</div>

<style>
  .thread-rows {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .row {
    display: flex;
    flex-direction: column;
  }
  .row.user {
    align-items: flex-end;
  }
  .row.waldo {
    align-items: flex-start;
  }
  .ubub {
    max-width: 80%;
    padding: 9px 13px;
    border-radius: 14px 14px 4px 14px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font-size: 0.9rem;
    line-height: 1.5;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .msg {
    max-width: 100%;
    color: var(--color-fg);
    font-size: 0.92rem;
    line-height: 1.6;
  }
  .msg.err {
    color: var(--color-err, #ef4444);
  }
  .typing {
    display: inline-flex;
    gap: 4px;
    padding: 8px 4px;
  }
  .typing span {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-fg-subtle);
    animation: bounce 1.2s infinite ease-in-out;
  }
  .typing span:nth-child(2) {
    animation-delay: 0.15s;
  }
  .typing span:nth-child(3) {
    animation-delay: 0.3s;
  }
  @keyframes bounce {
    0%, 80%, 100% {
      opacity: 0.3;
      transform: translateY(0);
    }
    40% {
      opacity: 1;
      transform: translateY(-3px);
    }
  }
  .status-line {
    align-self: center;
    font-size: 0.72rem;
    color: var(--color-fg-subtle);
    padding: 2px 0;
  }
</style>
