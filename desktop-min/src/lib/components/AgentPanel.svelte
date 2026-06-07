<script lang="ts">
  /**
   * AgentPanel — the right-side agent drawer (⌘J), 320–560px resizable.
   * This is the layout-level shell: header (new session + agent picker),
   * a thread region, and a composer. The full chat surface (ChatBlocks,
   * tool-call rendering, skill @-picker, live-audio controls) is its own
   * rebuild — kept as a labelled placeholder so the slot + resize are
   * real and the agent surface drops straight in.
   */
  import { Plus, ChevronDown, ArrowUp } from "@lucide/svelte";
  import { chrome } from "$lib/chrome.svelte";

  let width = $state(420);
  let dragging = false;

  function startResize(e: PointerEvent) {
    dragging = true;
    const startX = e.clientX;
    const startW = width;
    const move = (ev: PointerEvent) => {
      if (!dragging) return;
      width = Math.min(560, Math.max(320, startW - (ev.clientX - startX)));
    };
    const up = () => {
      dragging = false;
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }
</script>

<aside class="panel" style="width: {width}px" aria-label="Agent">
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="resize" onpointerdown={startResize} title="Resize"></div>
  <header class="hdr">
    <button type="button" class="iconbtn" title="New session" aria-label="New session">
      <Plus size={14} strokeWidth={2} />
    </button>
    <button type="button" class="picker" title="Agent">
      <span>workhorse</span>
      <ChevronDown size={13} strokeWidth={2} />
    </button>
  </header>

  <div class="thread">
    <p class="hint">Agent chat lands here.</p>
  </div>

  <div class="composer">
    <textarea class="ta" rows="2" placeholder="Message the agent…"></textarea>
    <button type="button" class="send" aria-label="Send" disabled>
      <ArrowUp size={14} strokeWidth={2.4} />
    </button>
  </div>
</aside>

<style>
  .panel {
    position: relative; flex-shrink: 0; display: flex; flex-direction: column;
    background: var(--color-surface); border-left: 1px solid var(--color-border);
    overflow: hidden;
  }
  .resize {
    position: absolute; top: 0; left: 0; width: 4px; height: 100%;
    cursor: col-resize; z-index: 2;
  }
  .resize:hover { background: var(--color-border-strong); }
  .hdr {
    display: flex; align-items: center; gap: 6px; padding: 8px;
    border-bottom: 1px solid var(--color-border);
  }
  .iconbtn {
    display: grid; place-items: center; width: 26px; height: 26px;
    border: 1px solid var(--color-border); border-radius: 7px;
    background: var(--color-surface-soft); color: var(--color-fg-muted); cursor: pointer;
  }
  .iconbtn:hover { color: var(--color-fg); }
  .picker {
    display: inline-flex; align-items: center; gap: 5px; height: 26px;
    padding: 0 0.55rem; border: 1px solid var(--color-border); border-radius: 7px;
    background: var(--color-surface-soft); color: var(--color-fg);
    font: inherit; font-size: 0.8rem; cursor: pointer;
  }
  .thread { flex: 1 1 auto; overflow-y: auto; padding: 1rem; }
  .hint { font-size: 0.8rem; color: var(--color-fg-subtle); }
  .composer {
    display: flex; align-items: flex-end; gap: 6px; padding: 8px;
    border-top: 1px solid var(--color-border);
  }
  .ta {
    flex: 1 1 auto; resize: none; max-height: 160px;
    background: var(--color-surface-soft); border: 1px solid var(--color-border);
    border-radius: 8px; padding: 0.5rem 0.6rem; color: var(--color-fg);
    font: inherit; font-size: 13.5px; line-height: 1.45; outline: none;
  }
  .ta:focus { border-color: var(--color-border-strong); }
  .send {
    display: grid; place-items: center; width: 28px; height: 28px; flex-shrink: 0;
    border: 0; border-radius: 999px; background: var(--color-fg);
    color: var(--color-page); cursor: pointer;
  }
  .send:disabled { opacity: 0.45; cursor: default; }
</style>
