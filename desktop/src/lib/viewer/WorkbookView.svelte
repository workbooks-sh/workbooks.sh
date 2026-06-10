<script lang="ts">
  /**
   * wb-i38o.9 — WorkbookView. Renders a prebuilt `.html` workbook in
   * a sandboxed iframe. We read the file as base64 from Rust, decode
   * to a Blob, and load via a blob: URL so the iframe gets its own
   * origin and the parent page can't be polluted by the workbook's
   * scripts.
   *
   * `allow-scripts` is required — workbooks ship with their own
   * runtime. No `allow-same-origin`, so a malicious workbook can't
   * reach back into the desktop's storage.
   *
   * Theme propagation: when the workbook loads
   * `@work.books/theme-tokens/apply-host-theme.js` it posts a
   * `wb-theme-ready` message to its parent. We catch that and reply
   * with the host's currently-applied token map. We also re-post
   * whenever the active theme changes so a desktop-side theme
   * switch immediately re-skins every open workbook tab.
   *
   * Security: the only payload travelling either direction is theme
   * tokens (CSS variable name → value pairs, all public design
   * data). The shim can only call `setProperty()` on its own :root.
   * No new capabilities, no exfiltration vector. The sandbox attr
   * still does all the heavy lifting.
   */
  import { invoke } from "@tauri-apps/api/core";
  import { onMount, onDestroy } from "svelte";
  import { themes } from "$lib/bridge/themes.svelte";
  import WorkbookProvenance from "$lib/network/components/WorkbookProvenance.svelte";

  let { path }: { path: string } = $props();

  let iframeEl = $state<HTMLIFrameElement | null>(null);
  let blobUrl = $state<string | null>(null);
  let htmlText = $state<string | null>(null);
  let phase = $state<"loading" | "ready" | "error">("loading");
  let error = $state<string | null>(null);

  /** True once the workbook announced itself via `wb-theme-ready`.
   *  Theme posts before this flips are deferred — the workbook's
   *  shim might not have attached its listener yet. */
  let workbookReady = $state(false);

  /** Most recently loaded path; guard against the $effect-on-path
   *  pattern firing redundantly on initial mount (which used to
   *  double-load and double-mount the iframe — root-cause of the
   *  freeze reported on kitchen-sink). */
  let loadedPath: string | null = null;

  /** activeId we last posted to the workbook; lets the theme-change
   *  effect early-out when nothing actually changed (effects often
   *  fire from reactive deps that don't represent a real change). */
  let lastPostedActiveId: string | null = null;

  async function load(p: string) {
    phase = "loading";
    error = null;
    workbookReady = false;
    lastPostedActiveId = null;
    htmlText = null;
    if (blobUrl) {
      URL.revokeObjectURL(blobUrl);
      blobUrl = null;
    }
    try {
      const b64 = await invoke<string>("read_file_bytes_base64", { path: p });
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      // Keep a text copy so WorkbookProvenance can run the verifier
      // on the bytes that actually shipped (no re-fetch from disk).
      htmlText = new TextDecoder("utf-8").decode(bytes);
      const blob = new Blob([bytes], { type: "text/html" });
      blobUrl = URL.createObjectURL(blob);
      phase = "ready";
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
      phase = "error";
    }
  }

  /** Capture the CSS variable values the desktop has applied to its
   *  own :root. We deliberately read from `getComputedStyle` — not
   *  from the themes store — so this function has zero reactive
   *  dependencies. (Reading `themes.active.light_tokens` inside an
   *  effect pulls the entire token map into the dep graph, which
   *  caused redundant effect runs on each token-map identity change.) */
  function currentTokens(): Record<string, string> {
    const cs = getComputedStyle(document.documentElement);
    const out: Record<string, string> = {};
    // Pull the union of known token names from the inline `applied`
    // tracker the themes store maintains — much cheaper than walking
    // every defined property on `:root`. Falls back to a sensible
    // built-in list when the store hasn't applied a theme yet.
    const names = themes.appliedTokenNames();
    for (const name of names) {
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
    } catch (err) {
      // Workbook iframe got torn down between our flag-check and the
      // actual post — silent no-op, the next load() will re-handshake.
      console.warn("[WorkbookView] postTokens failed:", err);
    }
  }

  function onWindowMessage(e: MessageEvent) {
    const data = e.data as { type?: unknown } | null;
    if (!data || typeof data !== "object") return;
    if (data.type !== "wb-theme-ready") return;
    if (iframeEl && e.source === iframeEl.contentWindow) {
      workbookReady = true;
      lastPostedActiveId = themes.activeId;
      postTokens();
    }
  }

  // Re-post tokens when the active theme changes — but only when it
  // actually changes. We track lastPostedActiveId so spurious effect
  // ticks (caused by other reactive reads) don't trigger a redundant
  // postMessage to a sandboxed iframe.
  $effect(() => {
    const cur = themes.activeId;
    if (!workbookReady) return;
    if (cur === lastPostedActiveId) return;
    lastPostedActiveId = cur;
    postTokens();
  });

  onMount(() => {
    window.addEventListener("message", onWindowMessage);
  });

  // Single source of truth for "load when path changes." The
  // path-equality guard prevents the dual-fire that onMount + a
  // bare $effect produced previously (mounting two iframes back to
  // back, with the first one destroyed mid-script-execution).
  $effect(() => {
    if (path && path !== loadedPath) {
      loadedPath = path;
      void load(path);
    }
  });

  onDestroy(() => {
    window.removeEventListener("message", onWindowMessage);
    if (blobUrl) URL.revokeObjectURL(blobUrl);
  });
</script>

<div class="workbook-frame">
  {#if phase === "loading"}
    <div class="status">Loading workbook…</div>
  {:else if phase === "error"}
    <div class="status err">Failed to load: {error}</div>
  {:else if blobUrl && htmlText}
    <!-- wb-5fl.7 — banner-only: the everyday verified badge + Share
         moved to the tab context menu; only the modified-after-publish
         warning still interrupts the page (it's a security signal). -->
    <WorkbookProvenance html={htmlText} bannerOnly={true} />
    <iframe
      bind:this={iframeEl}
      src={blobUrl}
      sandbox="allow-scripts"
      title={path}
    ></iframe>
  {/if}
</div>

<style>
  .workbook-frame {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  iframe {
    flex: 1 1 auto;
    border: 0;
    width: 100%;
    height: 100%;
    background: var(--color-page);
  }
  .status {
    flex: 1 1 auto;
    display: grid;
    place-items: center;
    color: var(--color-fg-muted);
    font-size: 0.95rem;
  }
  .status.err {
    color: #ef4444;
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.85rem;
    white-space: pre-wrap;
    padding: 2rem;
  }
</style>
