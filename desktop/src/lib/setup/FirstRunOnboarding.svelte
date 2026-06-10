<script lang="ts">
  /**
   * FirstRunOnboarding — the first-run gate (wb-hhf).
   *
   * Steps: Welcome → Account (optional, FIRST — signing in can resolve
   * a cloud/org runtime credential before we offer a local install,
   * wb-hhf.1) → Runtime (required) → Model key (required). Every
   * step's "done" state derives from REAL probes, never from "user
   * clicked next":
   *
   *   account  → auth.status === "signed-in"       (live store)
   *   runtime  → daemon.status.state === "ready"   (live store)
   *   key      → setup_status.has_model_key        (re-probed on save)
   *
   * GATE: the app is unusable until runtime + key verify; account is
   * educational/optional. Completion is plain app-directory data
   * (setup.json first_run_done via setup_complete_first_run) — NOT
   * tied to the auth token, so a signed-out user who passed once is
   * never re-gated.
   *
   * Runtime install runs IN-APP (the SetupWizard overlay drives
   * engine_detect / install / boot) — no separate OS installer.
   *
   * Target-awareness (web later): the runtime step reads capabilities
   * from probe results, not platform sniffing. On the web target the
   * probes report a hosted cloud runtime (paid) and only copy + CTA
   * swap — the verification skeleton stays.
   */
  import {
    RocketLaunch,
    Cpu,
    Key,
    UserCircle,
    CheckCircle,
    ArrowRight,
    CloudArrowUp,
    UsersThree,
    Globe,
    SquaresFour,
  } from "phosphor-svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { invoke } from "@tauri-apps/api/core";
  import AsciiShader from "$lib/ui/AsciiShader.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import {
    setupStatus,
    setupSaveModelKey,
    setupCompleteFirstRun,
  } from "$lib/bridge/setup.svelte";
  import { auth } from "$lib/auth/store.svelte";
  import { wizard } from "$lib/setup/wizard.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  const STEPS = ["welcome", "account", "runtime", "key"] as const;
  type Step = (typeof STEPS)[number];
  let step = $state<Step>("welcome");
  const stepIdx = $derived(STEPS.indexOf(step));

  // ── live verification ────────────────────────────────────────────
  const runtimeReady = $derived(sidecar.status.state === "ready");
  let hasModelKey = $state(false);
  const signedIn = $derived(auth.status === "signed-in");

  async function probeSetup() {
    try {
      const s = await setupStatus();
      hasModelKey = s.has_model_key;
    } catch {
      /* fail-open — probe again on save */
    }
  }
  $effect(() => {
    void probeSetup();
  });

  // ── model key form ───────────────────────────────────────────────
  let keyValue = $state("");
  let keyBusy = $state(false);
  let keyError = $state<string | null>(null);

  async function saveKey() {
    const v = keyValue.trim();
    if (!v || keyBusy) return;
    keyBusy = true;
    keyError = null;
    try {
      await setupSaveModelKey({
        name: "OpenRouter",
        provider: "openrouter",
        value: v,
      });
      keyValue = "";
      await probeSetup();
    } catch (e) {
      keyError = e instanceof Error ? e.message : String(e);
    } finally {
      keyBusy = false;
    }
  }

  // ── local-install capability (OS gate) ───────────────────────────
  // engine_detect says whether THIS machine can host a local runtime.
  // Unsupported OS → only cloud options render. Probe failure
  // fail-opens to supported (the wizard re-checks before installing).
  let localSupported = $state(true);
  let detectChecked = $state(false);
  // Entering the runtime step arms the embedded wizard flow (same store
  // as the modal, rendered inline here; the modal stays hidden).
  $effect(() => {
    if (step !== "runtime") return;
    void wizard.init();
    if (!runtimeReady && wizard.step === "closed") wizard.openEmbedded();
  });
  // The inline flow finished — refresh the daemon mirror immediately
  // (idempotent: daemon_up leaves a healthy runtime alone) instead of
  // waiting on the 3s state poll, so Continue unlocks right away.
  $effect(() => {
    if (step === "runtime" && wizard.step === "done" && !runtimeReady) {
      void sidecar.up().catch(() => {});
    }
  });
  $effect(() => {
    if (step !== "runtime" || detectChecked) return;
    detectChecked = true;
    void (async () => {
      try {
        const d = await invoke<{ supported?: boolean } | null>("engine_detect");
        if (d && d.supported === false) localSupported = false;
      } catch {
        /* fail-open */
      }
    })();
  });

  // ── cloud runtime via auth (wb-hhf.1) — graceful absence ─────────
  // When signed in, ask the broker for runtime credentials (an org or
  // hosted runtime). The Tauri command doesn't exist yet; the probe
  // fails silently and the local-install path renders instead.
  let cloudCreds = $state<{ url: string; token?: string } | null>(null);
  let cloudConnectBusy = $state(false);
  let cloudChecked = $state(false);
  $effect(() => {
    if (!signedIn || cloudChecked) return;
    cloudChecked = true;
    void (async () => {
      try {
        cloudCreds = await invoke<{ url: string; token?: string } | null>(
          "runtime_creds_fetch",
        );
      } catch {
        cloudCreds = null;
      }
    })();
  });
  async function connectCloudRuntime() {
    if (!cloudCreds || cloudConnectBusy) return;
    cloudConnectBusy = true;
    try {
      await invoke("engine_connect_cloud", {
        url: cloudCreds.url,
        token: cloudCreds.token ?? "",
      });
    } catch (e) {
      console.warn("[onboarding] cloud connect failed", e);
    } finally {
      cloudConnectBusy = false;
    }
  }

  // ── sign-in ──────────────────────────────────────────────────────
  let signInBusy = $state(false);
  async function doSignIn() {
    if (signInBusy) return;
    signInBusy = true;
    try {
      await auth.signIn();
    } catch {
      /* auth store surfaces errors */
    } finally {
      signInBusy = false;
    }
  }

  // ── navigation ───────────────────────────────────────────────────
  function next() {
    const i = STEPS.indexOf(step);
    if (i < STEPS.length - 1) step = STEPS[i + 1];
    else void finish();
  }
  function back() {
    const i = STEPS.indexOf(step);
    if (i > 0) step = STEPS[i - 1];
  }
  let finishing = $state(false);
  async function finish() {
    // The gate: requirements must VERIFY, not just be clicked through.
    if (finishing || !runtimeReady || !hasModelKey) return;
    finishing = true;
    try {
      await setupCompleteFirstRun();
    } catch (e) {
      console.warn("[onboarding] complete_first_run failed", e);
    }
    // Release the wizard store back to its modal skin (titlebar chip).
    wizard.embedded = false;
    wizard.step = "closed";
    oncomplete();
  }
</script>

<div class="screen">
  <AsciiShader />
  <div class="fade" aria-hidden="true"></div>
  <div class="card">
    <!-- progress dots -->
    <div class="dots" role="presentation">
      {#each STEPS as s, i (s)}
        <button
          type="button"
          class="dot"
          class:on={i === stepIdx}
          class:past={i < stepIdx}
          aria-label={s}
          onclick={() => {
            if (i <= stepIdx) step = s;
          }}
        ></button>
      {/each}
    </div>

    {#key step}
      <div class="body" in:fly={{ x: 16, duration: 200, easing: cubicOut }}>
        {#if step === "welcome"}
          <div class="hero"><RocketLaunch size={30} weight="fill" /></div>
          <h1>Welcome to Workbooks</h1>
          <p class="sub">
            Software that builds itself — workbooks are living apps your
            agents create and grow. A couple of quick steps and you're
            running.
          </p>
          <button type="button" class="primary" onclick={next}>
            Get started <ArrowRight size={14} weight="bold" />
          </button>

        {:else if step === "account"}
          <div class="hero"><UserCircle size={30} weight="fill" /></div>
          <h1>Sign in — optional</h1>
          <p class="sub">
            Workbooks works fully without an account. Signing in first
            lets us connect you to a cloud or team runtime automatically,
            and adds the connected layer:
          </p>
          <ul class="benefits">
            <li><Globe size={15} weight="fill" /> Join the network — share and discover workbooks</li>
            <li><CloudArrowUp size={15} weight="fill" /> One-click cloud deploys — we host your runtime</li>
            <li><UsersThree size={15} weight="fill" /> Team &amp; enterprise sharing, shared runtime credentials</li>
            <li><SquaresFour size={15} weight="fill" /> Manage every deployment from this app</li>
          </ul>
          {#if signedIn}
            <div class="status ok">
              <CheckCircle size={16} weight="fill" />
              Signed in as {auth.user?.displayName ?? auth.user?.email}
            </div>
          {:else}
            <button type="button" class="primary" onclick={doSignIn} disabled={signInBusy}>
              {signInBusy ? "Opening sign-in…" : "Sign in to Workbooks"}
            </button>
          {/if}
          <div class="nav">
            <button type="button" class="ghost" onclick={back}>Back</button>
            <button type="button" class={signedIn ? "primary" : "ghost"} onclick={next}>
              {signedIn ? "Continue" : "Continue without account"}
            </button>
          </div>

        {:else if step === "runtime"}
          <div class="hero"><Cpu size={30} weight="fill" /></div>
          <h1>Your runtime</h1>
          <p class="sub">
            The runtime is the engine that runs agents and builds
            workbooks. Install it right here — it runs privately on this
            machine and your files never leave it.
          </p>
          {#if runtimeReady}
            <div class="status ok">
              <CheckCircle size={16} weight="fill" />
              Runtime connected{sidecar.status.url ? ` — ${sidecar.status.url}` : ""}
            </div>
          {:else}
            <!-- The whole local/cloud flow runs INLINE here (the wizard
                 store in embedded mode — no separate modal). -->
            {#if wizard.step === "local-booting" || wizard.step === "local-detect" || (wizard.busy && wizard.step === "local-install")}
              <div class="status pending">
                {wizard.step === "local-booting" ? "Booting the engine…" : wizard.step === "local-detect" ? "Checking this machine…" : "Installing krunvm…"}
              </div>
              {#if wizard.pull?.total}
                {@const pct = Math.min(100, Math.round((wizard.pull.done / wizard.pull.total) * 100))}
                <div class="pull">
                  <div class="pull-bar">
                    <div class="pull-fill" style="width: {pct}%"></div>
                  </div>
                  <span class="pull-label">
                    Downloading engine image — {pct}% ·
                    {(wizard.pull.done / 1048576).toFixed(0)} / {(wizard.pull.total / 1048576).toFixed(0)} MB
                  </span>
                </div>
              {/if}
              {#if wizard.log.length}
                <div class="boot-log">
                  {#each wizard.log.slice(-4) as line, i (i)}
                    <div class="log-line">{line}</div>
                  {/each}
                </div>
              {/if}
            {:else if wizard.step === "local-install"}
              <p class="sub">
                The microVM backend (krunvm) isn't installed yet — install it
                via Homebrew right here.
              </p>
              <button type="button" class="primary" onclick={() => void wizard.installBackend()}>
                Install backend
              </button>
            {:else if wizard.step === "cloud-form" || wizard.step === "cloud-connecting"}
              <form
                class="key-form"
                onsubmit={(e) => {
                  e.preventDefault();
                  void wizard.connectCloud();
                }}
              >
                <input
                  type="text"
                  placeholder="https://your-runtime.example.com"
                  bind:value={wizard.cloudUrl}
                  spellcheck="false"
                />
                <input
                  type="password"
                  placeholder="token"
                  bind:value={wizard.cloudToken}
                  spellcheck="false"
                  autocomplete="off"
                />
                <button type="submit" class="primary" disabled={wizard.busy}>
                  {wizard.step === "cloud-connecting" ? "Connecting…" : "Connect"}
                </button>
              </form>
              {#if localSupported}
                <button type="button" class="ghost" onclick={() => void wizard.chooseLocal()}>
                  Run on this machine instead
                </button>
              {/if}
            {:else}
              <!-- choice — both options inline, side by side -->
              <div class="rt-choices">
                {#if localSupported}
                  <button type="button" class="primary" onclick={() => void wizard.chooseLocal()}>
                    <Cpu size={14} weight="fill" /> Run on this machine
                  </button>
                {/if}
                {#if cloudCreds}
                  <button
                    type="button"
                    class="primary"
                    onclick={() => void connectCloudRuntime()}
                    disabled={cloudConnectBusy}
                  >
                    <CloudArrowUp size={14} weight="fill" />
                    {cloudConnectBusy ? "Connecting…" : "Connect your cloud runtime"}
                  </button>
                {:else}
                  <button type="button" class={localSupported ? "ghost" : "primary"} onclick={() => wizard.chooseCloud()}>
                    <CloudArrowUp size={14} weight="fill" /> Connect to cloud
                  </button>
                {/if}
              </div>
              {#if !localSupported}
                <p class="sub">Local runtime isn't supported on this OS.</p>
              {/if}
            {/if}
            {#if wizard.error}
              <p class="err">{wizard.error}</p>
            {/if}
          {/if}
          <div class="nav">
            <button type="button" class="ghost" onclick={back}>Back</button>
            <button
              type="button"
              class="primary"
              onclick={next}
              disabled={!runtimeReady}
              title={runtimeReady ? "" : "A connected runtime is required"}
            >
              Continue
            </button>
          </div>

        {:else}
          <div class="hero"><Key size={30} weight="fill" /></div>
          <h1>Connect a model</h1>
          <p class="sub">
            Agents think with a language model. Paste an
            <a href="https://openrouter.ai/keys" target="_blank" rel="noreferrer">OpenRouter key</a>
            — one key, every model — and it's stored in your OS keychain,
            then handed to the runtime.
          </p>
          {#if hasModelKey}
            <div class="status ok">
              <CheckCircle size={16} weight="fill" /> Model key saved
            </div>
          {:else}
            <form
              class="key-form"
              onsubmit={(e) => {
                e.preventDefault();
                void saveKey();
              }}
            >
              <input
                type="password"
                placeholder="sk-or-…"
                bind:value={keyValue}
                spellcheck="false"
                autocomplete="off"
              />
              <button type="submit" class="primary" disabled={!keyValue.trim() || keyBusy}>
                {keyBusy ? "Saving…" : "Save"}
              </button>
            </form>
            {#if keyError}<p class="err">{keyError}</p>{/if}
          {/if}
          <div class="nav">
            <button type="button" class="ghost" onclick={back}>Back</button>
            <button
              type="button"
              class="primary"
              onclick={() => void finish()}
              disabled={!hasModelKey || finishing}
              title={hasModelKey ? "" : "A model key is required"}
            >
              {finishing ? "Finishing…" : "Finish"}
            </button>
          </div>
        {/if}
      </div>
    {/key}
  </div>
</div>

<style>
  /* Lander skin (web/lander) — this screen is the brand moment, so it
   * uses the lander's own dark tokens regardless of app color scheme:
   * bg #0c0d10, panel #14161b, line #262a32, ink #eceef2, dim #8b909a,
   * live green #3fe081 primary, mono CTAs. */
  .screen {
    flex: 1 1 auto;
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
    background: #0c0d10;
    overflow: hidden;
  }
  .fade {
    position: absolute;
    inset: auto 0 0 0;
    height: 40%;
    background: linear-gradient(transparent, #0c0d10);
    pointer-events: none;
  }
  .card {
    position: relative;
    width: 100%;
    max-width: 440px;
    background: color-mix(in srgb, #14161b 88%, transparent);
    backdrop-filter: blur(8px);
    border: 0;
    border-radius: 14px;
    box-shadow: 0 24px 80px rgba(0, 0, 0, 0.5);
    padding: 1.5rem 2rem 1.75rem;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    color: #eceef2;
  }
  .dots {
    display: flex;
    justify-content: center;
    gap: 7px;
    margin-bottom: 1.1rem;
  }
  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    border: 0;
    padding: 0;
    background: #262a32;
    cursor: pointer;
    transition: background 0.15s, transform 0.15s;
  }
  .dot.on {
    background: #3fe081;
    transform: scale(1.25);
  }
  .dot.past { background: rgba(63, 224, 129, 0.45); }

  .body {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.9rem;
  }
  .hero {
    display: grid;
    place-items: center;
    width: 56px;
    height: 56px;
    border-radius: 16px;
    background: rgba(63, 224, 129, 0.14);
    color: #3fe081;
  }
  h1 {
    margin: 0;
    font-size: 1.25rem;
    font-weight: 600;
    letter-spacing: -0.01em;
    color: #eceef2;
  }
  .sub {
    margin: 0;
    font-size: 0.86rem;
    line-height: 1.55;
    color: #8b909a;
    max-width: 36ch;
  }
  .sub a { color: #3fe081; }

  .benefits {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 7px;
    text-align: left;
    font-size: 0.83rem;
    color: #eceef2;
  }
  .benefits li {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .benefits :global(svg) { color: #3fe081; flex-shrink: 0; }

  .status {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 7px 13px;
    border-radius: 999px;
    font-size: 0.8rem;
    font-weight: 500;
    font-family: var(--mono, ui-monospace, monospace);
  }
  .status.ok {
    background: rgba(63, 224, 129, 0.14);
    color: #3fe081;
  }
  .status.pending {
    background: rgba(224, 179, 74, 0.14);
    color: #e0b34a;
  }
  .status.idle {
    background: #191c22;
    color: #8b909a;
  }

  .rt-choices {
    display: flex;
    flex-direction: column;
    gap: 8px;
    width: 100%;
    align-items: stretch;
  }
  .pull {
    display: flex;
    flex-direction: column;
    gap: 6px;
    width: 100%;
  }
  .pull-bar {
    height: 6px;
    border-radius: 999px;
    background: #191c22;
    overflow: hidden;
  }
  .pull-fill {
    height: 100%;
    border-radius: 999px;
    background: linear-gradient(90deg, #3fe081, #2f6fe0);
    transition: width 0.6s ease;
  }
  .pull-label {
    font-family: ui-monospace, monospace;
    font-size: 11px;
    color: #8b909a;
  }

  .boot-log {
    width: 100%;
    padding: 8px 10px;
    border-radius: 9px;
    background: #0c0d10;
    border: 1px solid #262a32;
    text-align: left;
  }
  .log-line {
    font-family: ui-monospace, monospace;
    font-size: 11px;
    line-height: 1.6;
    color: #8b909a;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .log-line:last-child { color: #3fe081; }

  .key-form {
    display: flex;
    gap: 7px;
    width: 100%;
  }
  .key-form input {
    flex: 1 1 auto;
    min-width: 0;
    padding: 8px 11px;
    border: 1px solid #262a32;
    border-radius: 9px;
    background: #0c0d10;
    color: #eceef2;
    font: inherit;
    font-size: 0.84rem;
    font-family: ui-monospace, monospace;
  }
  .key-form input:focus {
    outline: none;
    border-color: rgba(63, 224, 129, 0.5);
  }
  .err {
    margin: 0;
    font-size: 0.75rem;
    color: #ef4444;
  }

  /* Lander CTA: live green, dark ink text, mono. */
  .primary {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    padding: 11px 18px;
    border: 0;
    border-radius: 10px;
    background: #3fe081;
    color: #04130a;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 0.82rem;
    font-weight: 500;
    letter-spacing: -0.01em;
    cursor: pointer;
    transition: filter 0.12s, transform 0.12s;
  }
  .primary:hover:not(:disabled) { filter: brightness(1.08); }
  .primary:active:not(:disabled) { transform: scale(0.985); }
  .primary:disabled { opacity: 0.45; cursor: default; }

  .ghost {
    padding: 9px 14px;
    border: 0;
    border-radius: 10px;
    background: transparent;
    color: #8b909a;
    font: inherit;
    font-size: 0.84rem;
    cursor: pointer;
  }
  .ghost:hover { color: #eceef2; }

  .nav {
    display: flex;
    justify-content: space-between;
    width: 100%;
    margin-top: 0.4rem;
  }
</style>
