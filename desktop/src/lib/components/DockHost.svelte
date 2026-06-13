<script lang="ts">
  /**
   * DockHost (wb-aakl.14) — the right-side extension dock.
   *
   * Renders the active dock panel: an eager/lazy Svelte component (DOM-
   * mounted, inherits the theme for free) or an iframe-mounted toolkit UI
   * (themed via the wb-theme postMessage shim, same as WorkbookView).
   * Header carries the title + a close affordance; a left-edge handle
   * resizes the dock, persisted via the dock store.
   */
  import { X } from "phosphor-svelte";
  import { dock } from "$lib/bridge/dock.svelte";
  import { themes } from "$lib/bridge/themes.svelte";

  let iframeEl: HTMLIFrameElement | undefined = $state();
  let iframeReady = $state(false);
  let lastPostedActiveId = $state<string | null>(null);

  const active = $derived(dock.active);

  // ── resize (drag the left edge) ──────────────────────────────────
  let dragging = $state(false);
  function startResize(e: PointerEvent) {
    dragging = true;
    const startX = e.clientX;
    const startW = dock.width;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    const move = (ev: PointerEvent) => {
      if (!dragging) return;
      // dock is on the right, so dragging left (smaller clientX) widens it.
      dock.setWidth(startW + (startX - ev.clientX));
    };
    const up = () => {
      dragging = false;
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }

  // ── iframe theming (reuse the WorkbookView handshake) ─────────────
  function currentTokens(): Record<string, string> {
    const cs = getComputedStyle(document.documentElement);
    const out: Record<string, string> = {};
    for (const name of themes.appliedTokenNames()) {
      const v = cs.getPropertyValue(`--${name}`).trim();
      if (v) out[name] = v;
    }
    return out;
  }
  function postTokens() {
    const win = iframeEl?.contentWindow;
    if (!win) return;
    try {
      win.postMessage({ type: "wb-theme", tokens: currentTokens() }, "*");
    } catch {
      /* iframe torn down mid-post — next load re-handshakes */
    }
  }
  function onWindowMessage(e: MessageEvent) {
    const data = e.data as { type?: unknown } | null;
    if (!data || typeof data !== "object" || data.type !== "wb-theme-ready") return;
    if (iframeEl && e.source === iframeEl.contentWindow) {
      iframeReady = true;
      lastPostedActiveId = themes.activeId;
      postTokens();
    }
  }
  $effect(() => {
    const cur = themes.activeId;
    if (!iframeReady) return;
    if (cur === lastPostedActiveId) return;
    lastPostedActiveId = cur;
    postTokens();
  });
  // Reset the handshake when the active iframe panel changes.
  $effect(() => {
    void active?.id;
    iframeReady = false;
  });

  // Lazy component resolution — cache the resolved component on the panel.
  async function resolveComponent(p: NonNullable<typeof active>) {
    if (p.component) return p.component;
    if (p.load) {
      const m = await p.load();
      p.component = m.default;
      return p.component;
    }
    return null;
  }
</script>

<svelte:window onmessage={onWindowMessage} />

{#if active}
  <aside
    class="dock"
    style="width: {dock.width}px"
    aria-label={active.title}
  >
    <div
      class="resize"
      class:dragging
      role="separator"
      aria-label="Resize dock"
      onpointerdown={startResize}
    ></div>
    <header class="dock-head">
      <span class="dock-title">{active.title}</span>
      <button type="button" class="close" title="Close" aria-label="Close panel" onclick={() => dock.close()}>
        <X weight="bold" size={13} />
      </button>
    </header>
    <div class="dock-body">
      {#if active.iframeSrc}
        <iframe bind:this={iframeEl} src={active.iframeSrc} title={active.title} onload={postTokens}></iframe>
      {:else}
        {#await resolveComponent(active) then C}
          {#if C}
            <C {...active.props ?? {}} />
          {/if}
        {/await}
      {/if}
    </div>
  </aside>
{/if}

<style>
  .dock {
    position: relative;
    flex-shrink: 0;
    min-width: 320px;
    max-width: 720px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    background: var(--color-surface);
    border-left: 1px solid var(--color-border);
  }
  .resize {
    position: absolute;
    top: 0;
    left: -3px;
    width: 6px;
    height: 100%;
    cursor: col-resize;
    z-index: 5;
  }
  .resize:hover,
  .resize.dragging {
    background: var(--color-ring);
  }
  .dock-head {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 8px;
    height: 40px;
    padding: 0 8px 0 14px;
    border-bottom: 1px solid var(--color-border);
  }
  .dock-title {
    flex: 1;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.09em;
    text-transform: uppercase;
    color: var(--color-fg);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .close {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border: 0;
    border-radius: 7px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
  }
  .close:hover {
    background: color-mix(in srgb, var(--color-fg) 6%, transparent);
    color: var(--color-fg);
  }
  .dock-body {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .dock-body iframe {
    flex: 1;
    width: 100%;
    border: 0;
    background: var(--color-page);
  }
</style>
