<script lang="ts">
  /**
   * LiveBar — the bottom-of-shell strip for an active Gemini Live
   * session.
   *
   * Visual:
   *  - Collapsed (6px) — a thin animated gradient bar spanning the
   *    window width. Colors flow left → right driven by the theme
   *    aurora palette. Stays visible whenever a session is present
   *    (connecting / live / paused / error).
   *  - Expanded (56px) — same gradient as a background, with a
   *    floating control row on top (status pill + mute, pause/resume,
   *    end). Triggered by hover or by state transitions.
   *
   * Behaviour:
   *  - On state→connecting: auto-expand immediately and hold (no
   *    auto-collapse during connect — the user wants to see status).
   *  - On state→live (first time per session): hold expanded for
   *    ~1.6s so the user clocks the controls, then collapse.
   *  - Hover anywhere on the bar re-expands it; mouseleave collapses
   *    after a short delay.
   *  - On state→error: stay expanded so the error message is visible.
   *
   * Audio-reactive: input + output levels modulate the gradient's
   * scroll speed and saturation.
   */

  import { Mic, MicOff, Pause, Play } from "@lucide/svelte";
  import { geminiLive } from "$lib/live/gemini.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";

  let expanded = $state(false);
  let prevState = $state(geminiLive.state);
  let collapseTimer = 0;

  function clearCollapseTimer() {
    if (collapseTimer) {
      clearTimeout(collapseTimer);
      collapseTimer = 0;
    }
  }

  $effect(() => {
    const s = geminiLive.state;
    if (s === "connecting" || s === "error") {
      // Hold expanded during connect / on error so the user sees
      // status feedback.
      clearCollapseTimer();
      expanded = true;
    } else if (s === "live" && prevState !== "live") {
      // Just transitioned to live — show the controls briefly, then
      // squish down.
      clearCollapseTimer();
      expanded = true;
      collapseTimer = window.setTimeout(() => {
        expanded = false;
      }, 1600);
    } else if (s === "paused") {
      // Paused state stays expanded so the user can see + click Resume.
      clearCollapseTimer();
      expanded = true;
    }
    prevState = s;
  });

  function onMouseEnter() {
    clearCollapseTimer();
    expanded = true;
  }

  function onMouseLeave() {
    // Don't auto-collapse from paused / connecting / error states.
    if (
      geminiLive.state === "paused" ||
      geminiLive.state === "connecting" ||
      geminiLive.state === "error"
    ) {
      return;
    }
    clearCollapseTimer();
    collapseTimer = window.setTimeout(() => {
      expanded = false;
    }, 350);
  }

  // Combine mic + playback levels into one reactive driver.
  const audioLevel = $derived(
    Math.max(geminiLive.inputLevel, geminiLive.outputLevel),
  );

  // Status label derived from session state.
  const statusLabel = $derived.by(() => {
    switch (geminiLive.state) {
      case "connecting":
        return "Connecting…";
      case "live":
        return geminiLive.muted ? "Muted" : "Listening";
      case "paused":
        return "Paused";
      case "error":
        return geminiLive.error ?? "Error";
      default:
        return "";
    }
  });

  function handlePauseResume() {
    if (geminiLive.state === "paused") {
      void geminiLive.resume();
    } else if (geminiLive.state === "live") {
      void geminiLive.pause();
    }
  }
</script>

<!-- Hide the global LiveBar while the palette modal is open: the
     palette renders its own status inline, and we don't want two
     competing voice UIs at once (wb-dj5r). -->
{#if geminiLive.present && !chrome.paletteOpen}
  <div
    class="live-bar"
    class:expanded
    class:muted={geminiLive.muted}
    class:errored={geminiLive.state === "error"}
    style="--audio-level: {audioLevel.toFixed(3)};"
    onmouseenter={onMouseEnter}
    onmouseleave={onMouseLeave}
    role="region"
    aria-label="Live session controls"
  >
    <div class="strip" aria-hidden="true"></div>

    {#if expanded}
      <div class="controls">
        <span class="status">
          <span class="dot"></span>
          <span class="label">{statusLabel}</span>
        </span>

        <div class="actions">
          {#if geminiLive.state === "live"}
            <button
              type="button"
              class="btn"
              onclick={() => geminiLive.toggleMute()}
              title={geminiLive.muted ? "Unmute (space)" : "Mute (space)"}
              aria-label={geminiLive.muted ? "Unmute" : "Mute"}
            >
              {#if geminiLive.muted}
                <MicOff size={13} strokeWidth={2} />
              {:else}
                <Mic size={13} strokeWidth={2} />
              {/if}
            </button>
            <button
              type="button"
              class="btn"
              onclick={handlePauseResume}
              title="Pause — keeps session for resume"
              aria-label="Pause session"
            >
              <Pause size={13} strokeWidth={2} />
            </button>
          {:else if geminiLive.state === "paused"}
            <button
              type="button"
              class="btn primary"
              onclick={handlePauseResume}
              title="Resume — pick up where you left off"
              aria-label="Resume session"
            >
              <Play size={13} strokeWidth={2} />
              <span>Resume</span>
            </button>
          {/if}
        </div>
      </div>
    {/if}
  </div>
{/if}

<style>
  .live-bar {
    flex: 0 0 auto;
    width: 100%;
    height: 6px;
    position: relative;
    overflow: hidden;
    background: var(--color-surface);
    border-top: 1px solid var(--color-border);
    transition: height 260ms cubic-bezier(0.2, 0.7, 0.2, 1);
  }
  .live-bar.expanded {
    height: 56px;
  }
  .live-bar.errored .strip {
    /* Tint the strip red on error so it's unmistakable. */
    background: linear-gradient(
      90deg,
      rgba(239, 68, 68, 0.85),
      rgba(220, 38, 38, 0.85),
      rgba(239, 68, 68, 0.85)
    );
  }

  .strip {
    position: absolute;
    inset: 0;
    /* Doubled-up gradient so background-position animation scrolls
     * seamlessly. Saturation lifts with audio level so loud audio
     * visibly brightens the bar. */
    background: linear-gradient(
      90deg,
      var(--gradient-aurora-a),
      var(--gradient-aurora-b),
      var(--gradient-aurora-c),
      var(--gradient-aurora-d),
      var(--gradient-aurora-a),
      var(--gradient-aurora-b),
      var(--gradient-aurora-c),
      var(--gradient-aurora-d)
    );
    background-size: 200% 100%;
    /* Speed up with audio level. 12s baseline → ~4s at full level. */
    animation: strip-flow calc(12s - 8s * var(--audio-level, 0)) linear
      infinite;
    filter: saturate(calc(1 + 0.4 * var(--audio-level, 0)))
      brightness(calc(1 + 0.15 * var(--audio-level, 0)));
  }
  @keyframes strip-flow {
    from { background-position: 0% 0%; }
    to   { background-position: 200% 0%; }
  }
  .live-bar.muted .strip {
    filter: saturate(0.5) brightness(0.7);
  }

  .controls {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 0.85rem;
    /* Glass-y overlay so the gradient still shows through behind
     * the controls. */
    background: linear-gradient(
      to top,
      color-mix(in srgb, var(--color-surface) 70%, transparent),
      color-mix(in srgb, var(--color-surface) 40%, transparent) 65%,
      transparent
    );
    backdrop-filter: blur(6px);
    -webkit-backdrop-filter: blur(6px);
  }
  .status {
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    font-size: 12.5px;
    font-weight: 500;
    color: var(--color-fg);
  }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #34d399;
    box-shadow: 0 0 8px rgba(52, 211, 153, 0.7);
    animation: dot-pulse 1.6s ease-out infinite;
  }
  .live-bar.muted .dot {
    background: #fbbf24;
    box-shadow: none;
    animation: none;
  }
  .live-bar.errored .dot {
    background: #ef4444;
    box-shadow: none;
    animation: none;
  }
  @keyframes dot-pulse {
    0%   { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.7); }
    70%  { box-shadow: 0 0 0 6px rgba(52, 211, 153, 0); }
    100% { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0); }
  }

  .actions {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    height: 28px;
    padding: 0 0.55rem;
    border-radius: 6px;
    border: 1px solid var(--color-border);
    background: color-mix(in srgb, var(--color-surface) 85%, transparent);
    color: var(--color-fg);
    cursor: pointer;
    font: inherit;
    font-size: 12px;
  }
  .btn:hover {
    background: var(--color-surface);
    border-color: var(--color-border-strong);
  }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: var(--color-fg);
  }
  .btn.primary:hover {
    opacity: 0.9;
  }

  @media (prefers-reduced-motion: reduce) {
    .live-bar { transition: none; }
    .strip { animation: none; }
    .dot { animation: none; }
  }
</style>
