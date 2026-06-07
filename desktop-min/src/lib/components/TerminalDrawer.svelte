<script lang="ts">
  /**
   * TerminalDrawer — the bottom drawer (⌃`), height persisted to the
   * settings store. This is the layout-level shell: a resize handle, a
   * header strip, and a body placeholder. The real xterm.js multi-session
   * surface (pinned sidecar-log session, pty shells, session list) is its
   * own rebuild — the slot + persisted height are wired so it drops in.
   */
  import { onMount } from "svelte";
  import { X } from "@lucide/svelte";
  import { chrome } from "$lib/chrome.svelte";
  import { store } from "$lib/store.svelte";

  const KEY = "terminal.height";
  let height = $state(220);
  let dragging = false;

  onMount(async () => {
    const saved = await store.get<number>(KEY);
    if (typeof saved === "number") height = saved;
  });

  function startResize(e: PointerEvent) {
    dragging = true;
    const startY = e.clientY;
    const startH = height;
    const move = (ev: PointerEvent) => {
      if (!dragging) return;
      height = Math.max(120, startH - (ev.clientY - startY));
    };
    const up = () => {
      dragging = false;
      void store.set(KEY, height);
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }
</script>

<section class="drawer" style="height: {height}px" aria-label="Terminal">
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="resize" onpointerdown={startResize} title="Resize"></div>
  <header class="hdr">
    <span class="dot dot-ok"></span>
    <span class="title">sidecar-log</span>
    <span class="spacer"></span>
    <button type="button" class="x" aria-label="Close terminal" onclick={() => (chrome.terminalOpen = false)}>
      <X size={13} strokeWidth={2} />
    </button>
  </header>
  <pre class="body">$ engine ready — terminal sessions land here.</pre>
</section>

<style>
  .drawer {
    position: relative; flex-shrink: 0; display: flex; flex-direction: column;
    background: var(--color-page); border-top: 1px solid var(--color-border); overflow: hidden;
  }
  .resize {
    position: absolute; top: 0; left: 0; width: 100%; height: 4px;
    cursor: row-resize; z-index: 2;
  }
  .resize:hover { background: var(--color-border-strong); }
  .hdr {
    display: flex; align-items: center; gap: 7px; padding: 5px 8px;
    border-bottom: 1px solid var(--color-border); font-size: 0.74rem;
    color: var(--color-fg-muted);
  }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--color-fg-muted); }
  .dot-ok { background: var(--color-ok); }
  .title { font-weight: 500; }
  .spacer { flex: 1 1 auto; }
  .x {
    display: grid; place-items: center; width: 20px; height: 20px;
    border: 0; border-radius: 5px; background: transparent;
    color: var(--color-fg-muted); cursor: pointer;
  }
  .x:hover { background: var(--color-surface-soft); color: var(--color-fg); }
  .body {
    flex: 1 1 auto; margin: 0; padding: 0.6rem 0.75rem; overflow: auto;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px; line-height: 1.5; color: var(--color-fg);
  }
</style>
