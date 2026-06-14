<script lang="ts">
  /**
   * WaveletPlayer — the view half of wavelet (Phase 4).
   *
   * Plays a wavelet composition (plain HTML+CSS @keyframes, or the gm-*
   * web-component family) INLINE in the desktop app with transport
   * (play / pause / scrub) and an export=download affordance.
   *
   * PREVIEW == RENDER. The render core (render_seq.wasm — Blitz+Stylo)
   * produces frame N by seeking the CSS-animation clock to t = N / fps
   * and repainting. We load the SAME composition source and drive its
   * clock with the browser twin of that seek: the Web Animations API
   * (pause every animation, pin currentTime = t). So a paused/scrubbed
   * frame here equals the byte the renderer writes to frame_%05dN.png.
   *
   * The composition runs in a sandboxed iframe (allow-scripts, NO
   * allow-same-origin) so it gets its own origin and can't reach the
   * desktop's storage. Because the parent can't touch a cross-origin
   * iframe document, all transport flows over postMessage to an injected
   * bridge (/wavelet/transport-bridge.js). gm-* compositions also get the
   * wavelet runtime (/wavelet/wavelet-runtime.js) injected so their
   * custom elements register.
   *
   * Composition metadata (fps / duration / resolution) is read from the
   * composition's own <meta> tags, with the render-core arg defaults as
   * fallback (1280x720, fps 30, duration 2.0s) — so the transport's
   * timeline matches what `wavelet render` would emit for the same file.
   */
  import { invoke } from "@tauri-apps/api/core";
  import { onDestroy } from "svelte";

  let { path }: { path: string } = $props();

  // render-core arg defaults (Phase 3 surface): w 1280, h 720, fps 30, dur 2.0
  const DEF_FPS = 30;
  const DEF_DUR_MS = 2000;
  const DEF_W = 1280;
  const DEF_H = 720;

  let iframeEl = $state<HTMLIFrameElement | null>(null);
  let blobUrl = $state<string | null>(null);
  let htmlText = $state<string | null>(null);
  let phase = $state<"loading" | "ready" | "error">("loading");
  let error = $state<string | null>(null);

  // transport state (driven by bridge metadata + tick messages)
  let ready = $state(false);
  let playing = $state(false);
  let fps = $state(DEF_FPS);
  let durationMs = $state(DEF_DUR_MS);
  let width = $state(DEF_W);
  let height = $state(DEF_H);
  let timeMs = $state(0);

  let loadedPath: string | null = null;

  // scale-to-fit: the stage is sized to the native composition resolution
  // and scaled down to fit its container (letterboxed), so the composition
  // coordinate space matches the renderer's exactly.
  let stageWrap = $state<HTMLDivElement | null>(null);
  let stageBox = $state<HTMLDivElement | null>(null);
  let scale = $state(1);
  function recomputeScale() {
    const wrap = stageWrap;
    if (!wrap || !width || !height) return;
    const pad = 32; // matches .stage-wrap padding * 2
    const aw = Math.max(1, wrap.clientWidth - pad);
    const ah = Math.max(1, wrap.clientHeight - pad);
    scale = Math.min(aw / width, ah / height, 1);
  }

  const totalFrames = $derived(Math.max(1, Math.round((durationMs / 1000) * fps)));
  const curFrame = $derived(Math.min(totalFrames - 1, Math.round((timeMs / 1000) * fps)));

  function fmt(ms: number): string {
    const s = ms / 1000;
    const mm = Math.floor(s / 60);
    const ss = s - mm * 60;
    return `${mm}:${ss.toFixed(2).padStart(5, "0")}`;
  }

  /** Build the iframe srcdoc-equivalent: the composition with the
   *  transport bridge injected (and the gm-* runtime when needed). We
   *  inject by string-splicing into <head> so it runs before the
   *  composition body paints. Plain CSS compositions skip the runtime. */
  /** Served base URL of the composition's directory, so relative asset
   *  paths (`<img src="assets/petal.png">`) resolve from inside the
   *  blob: iframe (which has an opaque origin and can't resolve a bare
   *  relative path on its own). The render core resolves the same paths
   *  against the composition dir via the FileNetProvider — this is the
   *  browser twin. */
  function baseHref(p: string): string {
    const dir = p.replace(/[^/]+$/, "");
    try {
      return new URL(dir, window.location.origin).href;
    } catch {
      return dir;
    }
  }

  function instrument(html: string, p: string): string {
    const needsRuntime = /<gm-doc[\s>]/i.test(html);
    // <base> must come first so the runtime/bridge module URLs and the
    // composition's own relative assets both resolve against the served
    // composition dir. We point absolute /wavelet/* at the origin
    // explicitly so the <base> doesn't redirect them.
    const origin = window.location.origin;
    const inject =
      `<base href="${baseHref(p)}">` +
      (needsRuntime
        ? `<script type="module" src="${origin}/wavelet/wavelet-runtime.js"><\/script>`
        : "") +
      `<script src="${origin}/wavelet/transport-bridge.js"><\/script>`;
    if (/<head[^>]*>/i.test(html)) {
      return html.replace(/<head([^>]*)>/i, `<head$1>${inject}`);
    }
    if (/<html[^>]*>/i.test(html)) {
      return html.replace(/<html([^>]*)>/i, `<html$1><head>${inject}</head>`);
    }
    return inject + html;
  }

  async function load(p: string) {
    phase = "loading";
    error = null;
    ready = false;
    playing = false;
    timeMs = 0;
    htmlText = null;
    if (blobUrl) {
      URL.revokeObjectURL(blobUrl);
      blobUrl = null;
    }
    try {
      const b64 = await invoke<string>("read_file_bytes_base64", { path: p });
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      htmlText = new TextDecoder("utf-8").decode(bytes);
      const instrumented = instrument(htmlText, p);
      const blob = new Blob([instrumented], { type: "text/html" });
      blobUrl = URL.createObjectURL(blob);
      phase = "ready";
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
      phase = "error";
    }
  }

  function send(msg: Record<string, unknown>) {
    const win = iframeEl?.contentWindow;
    if (!win) return;
    try {
      win.postMessage(msg, "*");
    } catch (err) {
      console.warn("[WaveletPlayer] postMessage failed:", err);
    }
  }

  function onWindowMessage(e: MessageEvent) {
    if (!iframeEl || e.source !== iframeEl.contentWindow) return;
    const d = e.data as { type?: string; [k: string]: unknown } | null;
    if (!d || typeof d !== "object") return;
    switch (d.type) {
      case "wavelet:ready":
        ready = true;
        if (typeof d.fps === "number" && d.fps > 0) fps = d.fps as number;
        if (typeof d.durationMs === "number" && d.durationMs > 0)
          durationMs = d.durationMs as number;
        if (typeof d.width === "number") width = d.width as number;
        if (typeof d.height === "number") height = d.height as number;
        timeMs = 0;
        break;
      case "wavelet:tick":
        if (typeof d.timeMs === "number") timeMs = d.timeMs as number;
        break;
      case "wavelet:ended":
        playing = false;
        break;
    }
  }

  function play() {
    if (!ready) return;
    playing = true;
    send({ type: "wavelet:play", fromMs: timeMs });
  }
  function pause() {
    playing = false;
    send({ type: "wavelet:pause" });
  }
  function toggle() {
    if (playing) pause();
    else play();
  }
  function seekMs(t: number) {
    timeMs = Math.max(0, Math.min(durationMs, t));
    playing = false;
    send({ type: "wavelet:seek", timeMs });
  }
  function onScrub(e: Event) {
    const v = Number((e.target as HTMLInputElement).value);
    // scrub by frame for render-equal precision
    seekMs((v / fps) * 1000);
  }
  function step(delta: number) {
    seekMs(((curFrame + delta) / fps) * 1000);
  }

  /** Export = download the composition as a self-contained .html that
   *  plays standalone. For gm-* compositions we inline the runtime so
   *  the file is portable; plain CSS compositions are already portable.
   *  This is the SAME source the renderer consumes — to mux an mp4, run
   *  `wavelet render <this.html> -o out.mp4` (the Phase-3 host command). */
  async function exportDownload() {
    if (!htmlText) return;
    let out = htmlText;
    if (/<gm-doc[\s>]/i.test(out)) {
      try {
        const res = await fetch("/wavelet/wavelet-runtime.js");
        if (res.ok) {
          const code = await res.text();
          const tag = `<script type="module">${code}<\/script>`;
          out = /<head[^>]*>/i.test(out)
            ? out.replace(/<head([^>]*)>/i, `<head$1>${tag}`)
            : tag + out;
        }
      } catch (err) {
        console.warn("[WaveletPlayer] runtime inline failed:", err);
      }
    }
    const blob = new Blob([out], { type: "text/html" });
    const url = URL.createObjectURL(blob);
    const name = (path.split("/").pop() ?? "composition.html").replace(/\.html?$/i, "") + ".html";
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  $effect(() => {
    if (path && path !== loadedPath) {
      loadedPath = path;
      void load(path);
    }
  });

  $effect(() => {
    window.addEventListener("message", onWindowMessage);
    return () => window.removeEventListener("message", onWindowMessage);
  });

  // Keep the scale correct as the container or composition size changes.
  $effect(() => {
    const wrap = stageWrap;
    if (!wrap) return;
    // touch width/height so the effect re-runs when metadata arrives
    void width;
    void height;
    recomputeScale();
    const ro = new ResizeObserver(() => recomputeScale());
    ro.observe(wrap);
    return () => ro.disconnect();
  });

  onDestroy(() => {
    if (blobUrl) URL.revokeObjectURL(blobUrl);
  });
</script>

<div class="player">
  <div class="stage-wrap" bind:this={stageWrap}>
    {#if phase === "loading"}
      <div class="status">Loading composition…</div>
    {:else if phase === "error"}
      <div class="status err">Failed to load: {error}</div>
    {:else if blobUrl}
      <!-- The composition paints at its native resolution (1280x720), then
           we CSS-scale the whole stage to fit — so element positions
           (left:480px etc.) land exactly where the renderer paints them.
           Scaling the box, not the iframe content, keeps preview == render. -->
      <div
        class="stage"
        bind:this={stageBox}
        style="width: {width}px; height: {height}px; transform: scale({scale}); transform-origin: center center;"
      >
        <iframe
          bind:this={iframeEl}
          src={blobUrl}
          sandbox="allow-scripts"
          title={path}
          style="width: {width}px; height: {height}px;"
        ></iframe>
      </div>
    {/if}
  </div>

  {#if phase === "ready"}
    <div class="transport" class:disabled={!ready}>
      <button
        class="play"
        onclick={toggle}
        disabled={!ready}
        title={playing ? "Pause" : "Play"}
        aria-label={playing ? "Pause" : "Play"}
      >
        {#if playing}❚❚{:else}▶{/if}
      </button>
      <button class="step" onclick={() => step(-1)} disabled={!ready} title="Previous frame">⟨</button>
      <button class="step" onclick={() => step(1)} disabled={!ready} title="Next frame">⟩</button>

      <input
        class="scrub"
        type="range"
        min="0"
        max={totalFrames - 1}
        step="1"
        value={curFrame}
        oninput={onScrub}
        disabled={!ready}
        aria-label="Scrub timeline"
      />

      <span class="time">{fmt(timeMs)} / {fmt(durationMs)}</span>
      <span class="frame">f {curFrame}/{totalFrames - 1} · {fps}fps</span>

      <button class="export" onclick={exportDownload} disabled={!htmlText} title="Download composition (.html)">
        Export ↓
      </button>
    </div>
  {/if}
</div>

<style>
  .player {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    background: var(--color-page);
  }
  .stage-wrap {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px;
    overflow: hidden;
    background:
      repeating-conic-gradient(
        color-mix(in srgb, var(--color-fg) 4%, transparent) 0% 25%,
        transparent 0% 50%
      )
      50% / 24px 24px;
  }
  .stage {
    flex: 0 0 auto;
    box-shadow: 0 8px 40px rgba(0, 0, 0, 0.35);
    border-radius: 6px;
    overflow: hidden;
    background: #000;
  }
  .stage iframe {
    display: block;
    border: 0;
  }
  .status {
    flex: 1 1 auto;
    display: grid;
    place-items: center;
    color: var(--color-fg-muted);
    font-size: 0.95rem;
  }
  .status.err {
    color: var(--color-err);
    font-family: var(--font-mono), ui-monospace, monospace;
    font-size: 0.85rem;
    white-space: pre-wrap;
    padding: 2rem;
  }
  .transport {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    border-top: 1px solid var(--color-border);
    background: var(--color-surface, var(--color-page));
    font-size: 0.8rem;
    color: var(--color-fg);
  }
  .transport.disabled {
    opacity: 0.6;
  }
  button {
    appearance: none;
    border: 1px solid var(--color-border);
    background: var(--color-page);
    color: var(--color-fg);
    border-radius: 6px;
    height: 28px;
    min-width: 28px;
    padding: 0 8px;
    cursor: pointer;
    font-size: 0.78rem;
    line-height: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  button:hover:not(:disabled) {
    border-color: var(--color-ring);
    background: color-mix(in srgb, var(--color-brand) 8%, var(--color-page));
  }
  button:disabled {
    cursor: default;
    opacity: 0.5;
  }
  .play {
    color: var(--color-brand);
    font-weight: 700;
  }
  .scrub {
    flex: 1 1 auto;
    accent-color: var(--color-brand);
    cursor: pointer;
  }
  .time,
  .frame {
    font-family: var(--font-mono), ui-monospace, monospace;
    color: var(--color-fg-muted);
    white-space: nowrap;
  }
  .export {
    margin-left: auto;
    font-weight: 600;
  }
</style>
