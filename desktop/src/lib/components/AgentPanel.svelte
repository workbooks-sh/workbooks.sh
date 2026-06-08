<script lang="ts">
  /**
   * AgentPanel — right-side drawer hosting the agent chat surface.
   *
   * Closing the panel is handled by the titlebar Agent button (⌘J) —
   * no inline close affordance. The header's "+" button creates a new
   * session, and per-agent actions live inside the agent picker
   * dropdown.
   */
  import ChatPanel from "$lib/chat/ChatPanel.svelte";
</script>

<aside class="agent-panel" aria-label="Agent">
  <ChatPanel />
</aside>

<style>
  .agent-panel {
    flex-shrink: 0;
    width: 420px;
    min-width: 320px;
    max-width: 560px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    background: var(--color-surface);
    border-left: 1px solid var(--color-border);
  }
</style>
