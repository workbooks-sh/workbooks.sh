<script lang="ts">
  // Web-host adapter — must load before any component's onMount so the
  // capability router is live when stores initialize (browser preview).
  import "$lib/platform/webHost";
  import { onMount } from "svelte";
  import "../app.css";
  import Titlebar from "$lib/components/Titlebar.svelte";
  import LiveBar from "$lib/components/LiveBar.svelte";
  import WorkgateModal from "$lib/workgate/WorkgateModal.svelte";
  import EnvRequestModal from "$lib/env_request/EnvRequestModal.svelte";
  import SidecarOfflineOverlay from "$lib/auth/SidecarOfflineOverlay.svelte";
  // SignInOverlay intentionally not imported — auth UI is flag-gated
  // (WB_FF_AUTH_UI, wb-aakl.3) and surfaces only via the GeneralSettings
  // account card. The sidecar-offline overlay below is NOT auth.
  // SetupWizard (in-app engine installer) is flag-gated (WB_FF_ONBOARDING,
  // wb-aakl.5) and lazily imported — the CLI owns runtime install now, so
  // a flags-off browser excludes the setup/ chunk entirely.
  import { auth } from "$lib/auth/store.svelte";
  import { geminiLive } from "$lib/live/gemini.svelte";
  import { features } from "$lib/bridge/features";
  import { onboarding } from "$lib/onboarding/onboarding.svelte";

  let SetupWizard =
    $state<typeof import("$lib/setup/SetupWizard.svelte").default | null>(null);
  $effect(() => {
    if (features.onboarding && !SetupWizard)
      void import("$lib/setup/SetupWizard.svelte").then((m) => (SetupWizard = m.default));
  });

  let { children } = $props();

  // App-level auth + sidecar probe. Runs once on mount; overlays
  // below render full-page when either check fails.
  onMount(() => {
    void auth.init();
    document.addEventListener("keydown", onGlobalKey);
    return () => document.removeEventListener("keydown", onGlobalKey);
  });

  // wb-xxbm.6 — space-to-mute global keybinding. Active only while a
  // live session is open and the focus isn't on an editable surface
  // (so typing a space in the composer still inserts a space).
  function onGlobalKey(e: KeyboardEvent) {
    if (e.code !== "Space" || !geminiLive.active) return;
    const t = e.target as HTMLElement | null;
    if (!t) return;
    const tag = t.tagName;
    if (
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      t.isContentEditable
    ) {
      return;
    }
    e.preventDefault();
    geminiLive.toggleMute();
  }
</script>

<div class="shell">
  <div class="tb-host" class:ob-hide={!onboarding.shows("titlebar")}>
    <Titlebar />
  </div>
  <div class="body">
    {@render children()}
  </div>
  <!-- wb-xxbm.6 — Gemini Live status + controls bar. Renders only
       when a session is present (connecting / live / paused / error).
       Collapsed to a thin animated gradient; expands on hover or
       state transitions to reveal mute / pause / resume / end. -->
  <LiveBar />
</div>

<!-- Sidecar gate at the app root. Sign-in is OPTIONAL — the rail
     avatar (and Settings → Account) are the entry points, and the
     app stays usable in the anonymous default state. Only the
     sidecar-unreachable overlay is a hard gate, because without
     Workhorse we can't do anything network-adjacent. -->
{#if auth.status === "sidecar-offline"}
  <SidecarOfflineOverlay />
{/if}

<!-- wb-80q0.10 — Workgate approval modal. Always mounted; renders
     only when the workgate store has a pending request. Sits OUTSIDE
     the .shell flex so it overlays the whole viewport. -->
<WorkgateModal />

<!-- Env-request modal — desktop surface for `wb env request`.
     Renders only when an agent / CLI asked for a credential. Same
     overlay treatment as WorkgateModal. -->
<EnvRequestModal />

<!-- Engine install wizard — flag-gated (WB_FF_ONBOARDING). Off in the
     shipped browser: the CLI installs the runtime, so there is no in-app
     installer. When on, renders only when opened from the titlebar chip. -->
{#if features.onboarding && SetupWizard}
  <SetupWizard />
{/if}

<style>
  /* Full-viewport shell. Titlebar sticks at the top; .body fills the
   * rest. The shell locks to viewport height (not min-height) and hides
   * its own overflow so the whole page can't scroll — individual panes
   * (chat thread, file tree, tab content) handle their own scroll. */
  :global(html),
  :global(body) {
    height: 100%;
    overflow: hidden;
  }
  /* Onboarding reveal: the real titlebar drops in as its own beat. */
  .tb-host {
    flex-shrink: 0;
    transition: opacity 0.4s ease, transform 0.45s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .tb-host.ob-hide {
    opacity: 0;
    transform: translateY(-12px);
    pointer-events: none;
  }
  .shell {
    display: flex;
    flex-direction: column;
    height: 100vh;
    overflow: hidden;
    /* Chrome frame color shows through the gaps around the floating
     * content canvas (inset style). */
    background: var(--color-chrome);
  }
  .body {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    overflow: hidden;
  }

</style>
