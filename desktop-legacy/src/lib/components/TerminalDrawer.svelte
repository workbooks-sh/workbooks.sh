<script lang="ts">
  /**
   * TerminalDrawer — multi-session embedded terminal.
   *
   * Layout: bottom drawer with two panes side-by-side:
   *
   *   ┌──────────────────────────────┬───────────────┐
   *   │   xterm (active session)     │ session list  │
   *   │                              │   ● sidecar   │
   *   │                              │   ◯ zsh       │
   *   │                              │   + new shell │
   *   └──────────────────────────────┴───────────────┘
   *
   * One xterm.js instance per session. We keep all of them mounted
   * (display:none for non-active) so switching is instant and each
   * session's scrollback is preserved. Memory cost is modest — each
   * xterm is ~100KB plus its scrollback buffer.
   *
   * The pinned `sidecar` session is special:
   *   - Not pty-backed. Subscribes to the `sidecar-log` event and
   *     writes each line into its xterm as text.
   *   - Read-only. We don't wire input handlers for it.
   *   - Always sits at the top of the session list; status dot tracks
   *     the sidecar's live state from `sidecar.svelte`.
   *
   * Pty-backed sessions (shell + install) own a Rust-side session_id;
   * keystrokes and resize go back over `terminal.write` / `terminal.resize`.
   */
  import { onDestroy } from "svelte";
  import { Terminal as Xterm } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import "@xterm/xterm/css/xterm.css";
  import { X, Plus, Pin, Terminal as TerminalIcon, Download } from "@lucide/svelte";
  import {
    terminal,
    terminalDrawer,
    SIDECAR_SESSION_ID,
    type SessionMeta,
  } from "$lib/bridge/terminal.svelte";
  import { sidecar as sidecarStore } from "$lib/bridge/sidecar.svelte";

  let hostEl: HTMLDivElement | undefined = $state();
  /** Map of session_id → mounted xterm + container ref + FitAddon. */
  type MountedSession = {
    xterm: Xterm;
    fit: FitAddon;
    container: HTMLDivElement;
  };
  const mounted = new Map<string, MountedSession>();

  // Drawer height — persisted to localStorage so toggling the drawer
  // doesn't lose the user's last drag. Clamped to a sensible range
  // (small enough to leave the main content visible; large enough to
  // be useful for a real terminal session).
  const HEIGHT_KEY = "wb-terminal-drawer-height";
  const MIN_HEIGHT = 120;

  function loadHeight(): number {
    const raw =
      typeof localStorage !== "undefined"
        ? localStorage.getItem(HEIGHT_KEY)
        : null;
    const parsed = raw ? Number(raw) : NaN;
    return Number.isFinite(parsed) && parsed >= MIN_HEIGHT ? parsed : 280;
  }

  let drawerHeight = $state(loadHeight());

  // Resize-handle drag state. Stored outside reactive state so the
  // pointermove handler can read/mutate without retriggering effects.
  let dragStartY = 0;
  let dragStartHeight = 0;
  let dragging = $state(false);

  /** Theme tokens that xterm.js wants as concrete hex strings. We
   *  read the CSS vars once at mount; theme switches re-mount via
   *  the open/close cycle. */
  function themeFromCss() {
    const styles = getComputedStyle(document.documentElement);
    const bg = styles.getPropertyValue("--color-page").trim() || "#0a0a0a";
    const fg = styles.getPropertyValue("--color-fg").trim() || "#e6e6e6";
    return { background: bg, foreground: fg, cursor: fg };
  }

  function newXterm(): { xterm: Xterm; fit: FitAddon } {
    const xterm = new Xterm({
      cursorBlink: true,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
      fontSize: 12,
      theme: themeFromCss(),
      scrollback: 5000,
    });
    const fit = new FitAddon();
    xterm.loadAddon(fit);
    return { xterm, fit };
  }

  /** Ensure the sidecar logs session is mounted + subscribed. Called
   *  once when the drawer opens. */
  function mountSidecar() {
    if (mounted.has(SIDECAR_SESSION_ID)) return;

    const container = document.createElement("div");
    container.className = "session-host";
    hostEl?.appendChild(container);

    const { xterm, fit } = newXterm();
    xterm.open(container);
    fit.fit();

    // Read-only banner so the user knows clicks/keys won't do anything.
    xterm.write(
      "\x1b[2m# Workhorse engine — read-only logs (stdout + stderr)\x1b[0m\r\n",
    );

    terminal.subscribeSidecarLogs(({ stream, line }) => {
      // Dim stderr lines so users can scan for errors.
      const prefix = stream === "stderr" ? "\x1b[33m" : "";
      const suffix = stream === "stderr" ? "\x1b[0m" : "";
      xterm.write(prefix + line + suffix + "\r\n");
    });

    mounted.set(SIDECAR_SESSION_ID, { xterm, fit, container });
  }

  /** Spawn a real pty-backed session (shell or install) + mount its
   *  xterm + subscribe to output events. */
  async function spawnPtySession(opts: {
    label: string;
    kind: "shell" | "install";
    command?: string[];
  }) {
    if (!hostEl) return;

    const container = document.createElement("div");
    container.className = "session-host";
    hostEl.appendChild(container);

    const { xterm, fit } = newXterm();
    xterm.open(container);
    fit.fit();

    const sessionId = await terminal.spawn({
      cols: xterm.cols,
      rows: xterm.rows,
      command: opts.command,
    });

    terminal.subscribe(
      sessionId,
      (bytes) => xterm.write(bytes),
      (exitCode) => {
        terminalDrawer.markExited(sessionId, exitCode);
        if (opts.kind === "install") {
          terminalDrawer.resolveInstall({ exit_code: exitCode });
        }
      },
    );

    xterm.onData((data) => terminal.writeString(sessionId, data));
    xterm.onResize(({ cols, rows }) => terminal.resize(sessionId, cols, rows));

    mounted.set(sessionId, { xterm, fit, container });

    terminalDrawer.registerSession({
      id: sessionId,
      label: opts.label,
      kind: opts.kind,
      state: "running",
      exit_code: null,
      closable: true,
    });
  }

  async function newShell() {
    await spawnPtySession({ label: "shell", kind: "shell" });
  }

  function showOnly(id: string) {
    for (const [sid, m] of mounted) {
      m.container.style.display = sid === id ? "block" : "none";
    }
    // Re-fit the now-visible xterm — sizes computed while hidden are
    // wrong. Schedule after the display flip flushes.
    requestAnimationFrame(() => {
      const active = mounted.get(id);
      active?.fit.fit();
    });
  }

  /** React to active-session changes. */
  $effect(() => {
    if (terminalDrawer.open) showOnly(terminalDrawer.activeId);
  });

  /** Pick up any pending install request. Spawns a new session for
   *  it rather than replacing the current one. */
  $effect(() => {
    if (!terminalDrawer.open) return;
    const req = terminalDrawer.takePendingInstall();
    if (req) {
      void spawnPtySession({
        label: req.label,
        kind: "install",
        command: req.command,
      });
    }
  });

  /** Mount the sidecar session whenever the drawer opens. Other
   *  sessions are spawned on demand. */
  $effect(() => {
    if (terminalDrawer.open && hostEl && !mounted.has(SIDECAR_SESSION_ID)) {
      mountSidecar();
    }
  });

  /** Mirror sidecar status into the session dot. */
  $effect(() => {
    const state = sidecarStore.status.state;
    if (state === "ready" || state === "starting" || state === "restarting") {
      terminalDrawer.setSidecarState("running");
    } else if (state === "crashed" || state === "unhealthy") {
      terminalDrawer.setSidecarState("failed");
    } else {
      terminalDrawer.setSidecarState("exited");
    }
  });

  /** Window resize → refit the active xterm. */
  function onWindowResize() {
    const active = mounted.get(terminalDrawer.activeId);
    active?.fit.fit();
  }

  function closeSession(s: SessionMeta) {
    if (!s.closable) return;
    const m = mounted.get(s.id);
    if (m) {
      m.xterm.dispose();
      m.container.remove();
      mounted.delete(s.id);
    }
    if (s.state === "running") {
      void terminal.kill(s.id).catch(() => {});
    }
    terminal.unsubscribe(s.id);
    terminalDrawer.removeSession(s.id);
  }

  onDestroy(() => {
    for (const [id, m] of mounted) {
      m.xterm.dispose();
      if (id !== SIDECAR_SESSION_ID) {
        void terminal.kill(id).catch(() => {});
      }
    }
    mounted.clear();
    terminal.unsubscribeSidecarLogs();
    terminal.stop();
  });

  function statusColor(s: SessionMeta): string {
    if (s.state === "running") return "var(--color-emerald, #10b981)";
    if (s.state === "failed") return "#ef4444";
    return "var(--color-fg-subtle)";
  }

  function activeMeta() {
    return terminalDrawer.sessions.find(
      (s) => s.id === terminalDrawer.activeId,
    );
  }

  // ── Resize handle ────────────────────────────────────────────────
  //
  // The handle sits along the top edge of the drawer. We grab it on
  // pointerdown, capture pointer events globally, and update height
  // until pointerup. Bounds: MIN_HEIGHT ≤ height ≤ 80% of viewport so
  // the drawer can never crowd out the rest of the app.

  function onResizePointerDown(e: PointerEvent) {
    e.preventDefault();
    dragging = true;
    dragStartY = e.clientY;
    dragStartHeight = drawerHeight;
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    window.addEventListener("pointermove", onResizePointerMove);
    window.addEventListener("pointerup", onResizePointerUp);
  }

  function onResizePointerMove(e: PointerEvent) {
    if (!dragging) return;
    const delta = dragStartY - e.clientY; // up = positive = bigger
    const max = Math.max(MIN_HEIGHT, Math.floor(window.innerHeight * 0.8));
    drawerHeight = Math.min(max, Math.max(MIN_HEIGHT, dragStartHeight + delta));
    // Refit the live xterm so the grid matches the new height.
    const active = mounted.get(terminalDrawer.activeId);
    active?.fit.fit();
  }

  function onResizePointerUp() {
    if (!dragging) return;
    dragging = false;
    window.removeEventListener("pointermove", onResizePointerMove);
    window.removeEventListener("pointerup", onResizePointerUp);
    try {
      localStorage.setItem(HEIGHT_KEY, String(drawerHeight));
    } catch {
      // localStorage can throw in private mode — swallow.
    }
  }
</script>

<svelte:window onresize={onWindowResize} />

{#if terminalDrawer.open}
  <aside
    class="drawer"
    style="height: {drawerHeight}px;"
    aria-label="Terminal"
    class:dragging
  >
    <!-- Drag bar along the top edge for height resize. Thin (4px) so
         the user has to deliberately grab it; bumps to a brighter
         color on hover so it's still discoverable. -->
    <div
      class="resize-handle"
      role="separator"
      aria-orientation="horizontal"
      aria-label="Resize terminal"
      onpointerdown={onResizePointerDown}
    ></div>

    <header class="drawer-head">
      {#if activeMeta()}
        {@const m = activeMeta()!}
        {#if m.kind === "install"}
          <Download size={13} strokeWidth={1.8} />
        {:else if m.kind === "sidecar"}
          <Pin size={13} strokeWidth={1.8} />
        {:else}
          <TerminalIcon size={13} strokeWidth={1.8} />
        {/if}
        <span class="label">{m.label}</span>
        {#if m.state !== "running"}
          <span class="state-tag" class:failed={m.state === "failed"}>
            {m.state}{m.exit_code !== null ? ` · ${m.exit_code}` : ""}
          </span>
        {/if}
      {/if}
      <span class="spacer"></span>
      <button
        type="button"
        class="head-btn"
        onclick={() => terminalDrawer.hide()}
        title="Close terminal"
        aria-label="Close terminal"
      >
        <X size={13} strokeWidth={2} />
      </button>
    </header>

    <!-- Body: xterm host on the left, vertical sessions column on
         the right. The header above spans both. -->
    <div class="body">
      <div class="host" bind:this={hostEl}></div>

      <aside class="sidebar" aria-label="Terminal sessions">
        <ul class="session-list">
          {#each terminalDrawer.sessions as s (s.id)}
            <li class="tab" class:active={s.id === terminalDrawer.activeId}>
              <button
                type="button"
                class="tab-pick"
                onclick={() => terminalDrawer.setActive(s.id)}
                title={s.label}
              >
                <span
                  class="status-dot"
                  style="background: {statusColor(s)};"
                ></span>
                <span class="tab-label">{s.label}</span>
                {#if !s.closable}
                  <Pin size={10} strokeWidth={1.8} />
                {/if}
              </button>
              {#if s.closable}
                <button
                  type="button"
                  class="tab-close"
                  onclick={() => closeSession(s)}
                  aria-label="Close session"
                  title="Close"
                >
                  <X size={10} strokeWidth={2.4} />
                </button>
              {/if}
            </li>
          {/each}
        </ul>
        <button
          type="button"
          class="new-shell"
          onclick={newShell}
          title="Spawn a new shell"
        >
          <Plus size={12} strokeWidth={2} /> New shell
        </button>
      </aside>
    </div>
  </aside>
{/if}

<style>
  .drawer {
    flex-shrink: 0;
    border-top: 1px solid var(--color-border);
    background: var(--color-page);
    display: flex;
    flex-direction: column;
    min-height: 0;
    /* Suppress text selection while the resize handle is being
     * dragged — without this, dragging selects all the chrome text. */
    user-select: auto;
  }
  .drawer.dragging {
    user-select: none;
  }
  .resize-handle {
    flex-shrink: 0;
    height: 4px;
    cursor: ns-resize;
    background: transparent;
    transition: background 0.1s;
    /* Slight margin into the drawer so the cursor change is generous
     * — the actual hit area extends 2px beyond the visible bar via
     * the negative margin trick. */
    margin-top: -2px;
    margin-bottom: -2px;
    position: relative;
    z-index: 1;
  }
  .resize-handle:hover,
  .drawer.dragging .resize-handle {
    background: var(--color-border-strong, var(--color-border));
  }
  .drawer-head {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.3rem 0.6rem;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
    font-size: 0.75rem;
  }
  .label {
    color: var(--color-fg);
    font-weight: 500;
  }
  .state-tag {
    font-size: 0.66rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 1px 6px;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-weight: 600;
  }
  .state-tag.failed {
    color: #ef4444;
    border-color: color-mix(in srgb, #ef4444 35%, var(--color-border));
  }
  .spacer { flex: 1 1 auto; }
  .head-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 5px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: background 0.1s, color 0.1s;
  }
  .head-btn:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .host {
    flex: 1 1 auto;
    min-height: 0;
    padding: 0.3rem 0.6rem;
    overflow: hidden;
    position: relative;
  }
  /* Each session gets its own absolutely-positioned host so they can
   * coexist without competing for layout; we toggle display per session
   * on switch. */
  .host :global(.session-host) {
    position: absolute;
    inset: 0;
    padding: 0.3rem 0;
  }

  /* Body: header above spans full width; below it splits into
   * xterm host (left) + sessions column (right). */
  .body {
    flex: 1 1 auto;
    display: flex;
    min-height: 0;
    min-width: 0;
  }

  /* Vertical sessions column on the right side of the body. */
  .sidebar {
    flex-shrink: 0;
    width: 180px;
    border-left: 1px solid var(--color-border);
    background: var(--color-surface);
    display: flex;
    flex-direction: column;
    min-height: 0;
  }
  .session-list {
    flex: 1 1 auto;
    list-style: none;
    margin: 0;
    padding: 0.3rem 0.25rem;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .tab {
    display: flex;
    align-items: center;
    gap: 0.2rem;
    border-radius: 6px;
    border-left: 2px solid transparent;
    transition: background 0.1s, border-color 0.1s;
  }
  .tab.active {
    background: var(--color-page);
    border-left-color: var(--color-fg);
  }
  .tab-pick {
    flex: 1 1 auto;
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.76rem;
    text-align: left;
    padding: 0.4rem 0.45rem;
    cursor: pointer;
    min-width: 0;
  }
  .tab.active .tab-pick {
    color: var(--color-fg);
  }
  .tab-label {
    flex: 1 1 auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }
  .status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .tab-close {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    margin-right: 0.25rem;
    border-radius: 4px;
    background: transparent;
    border: 0;
    color: var(--color-fg-subtle);
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.1s, color 0.1s, background 0.1s;
  }
  .tab:hover .tab-close,
  .tab.active .tab-close {
    opacity: 1;
  }
  .tab-close:hover {
    color: var(--color-fg);
    background: var(--color-surface-soft);
  }

  .new-shell {
    margin: 0.35rem 0.55rem 0.5rem;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.3rem;
    height: 26px;
    background: transparent;
    border: 1px dashed var(--color-border-strong, var(--color-border));
    border-radius: 6px;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.72rem;
    cursor: pointer;
    transition: color 0.1s, background 0.1s, border-color 0.1s;
  }
  .new-shell:hover {
    color: var(--color-fg);
    background: var(--color-surface-soft);
  }

  .host :global(.xterm-viewport) {
    scrollbar-width: thin;
  }
</style>
