<script lang="ts">
  /**
   * OfflineView — the hard gate shown when the engine sidecar is
   * unreachable (mirrors the old SidecarOfflineOverlay). The route guard
   * redirects here; a retry re-probes and returns to Create on success.
   */
  import { CloudOff, RefreshCw } from "@lucide/svelte";
  import { auth } from "$lib/auth.svelte";
  import { useRouter } from "@dvcol/svelte-simple-router/router";

  const router = useRouter();
  let busy = $state(false);

  // "Try again" actually restarts the engine process (not just a re-probe)
  // — a re-probe alone never recovers a crashed engine or a port conflict.
  // After the restart the store reflects whatever state we land in.
  async function retry() {
    busy = true;
    try {
      await auth.restartEngine();
      if (auth.sidecarReachable) void router.push({ name: "create" });
    } finally {
      busy = false;
    }
  }
</script>

<section class="offline">
  <CloudOff size={28} strokeWidth={1.6} />
  <h1>Engine unreachable</h1>
  <p>The local engine isn't responding. The app needs it to read and write your workbooks.</p>
  <button onclick={retry} disabled={busy}>
    <RefreshCw size={14} strokeWidth={1.8} /> {busy ? "Checking…" : "Retry"}
  </button>
</section>

<style>
  .offline {
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.6rem;
    text-align: center;
    color: var(--color-fg-muted);
    padding: 2rem;
  }
  h1 {
    margin: 0.3rem 0 0;
    font-size: 1.05rem;
    color: var(--color-fg);
  }
  p {
    margin: 0;
    max-width: 360px;
    font-size: 0.85rem;
  }
  button {
    margin-top: 0.6rem;
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    height: 32px;
    padding: 0 0.85rem;
    border-radius: 8px;
    border: 1px solid transparent;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 0.84rem;
    cursor: pointer;
  }
  button:disabled {
    opacity: 0.5;
    cursor: default;
  }
</style>
