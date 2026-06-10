<script lang="ts">
  /**
   * Install wizard — gets the runtime engine running. Two paths:
   *   • Local  → detect krunvm, install it if missing, boot a microVM (first
   *              run pulls the engine image), connect.
   *   • Cloud  → paste a URL + token, probe /health, persist.
   *
   * Offline-first: ALWAYS skippable. The app works with no engine; this only
   * upgrades it from "local-only" to "engine connected". Mounted once in
   * +layout.svelte; renders only when `wizard.step !== "closed"`.
   */
  import { onMount } from "svelte";
  import { Cpu, Cloud, DownloadSimple as Download, Check, X, ArrowsClockwise as RefreshCw, CircleNotch as Loader, WarningCircle as AlertCircle } from "phosphor-svelte";
  import { wizard } from "./wizard.svelte";

  onMount(() => {
    void wizard.init();
  });

  // Auto-close shortly after success so "done" reads as a confirmation, not a
  // dead-end the user must dismiss.
  $effect(() => {
    if (wizard.step === "done") {
      const t = setTimeout(() => wizard.close(), 1400);
      return () => clearTimeout(t);
    }
  });

  let logEl: HTMLDivElement | undefined = $state();
  // Pin the streaming log to the bottom as lines arrive.
  $effect(() => {
    void wizard.log.length;
    if (logEl) logEl.scrollTop = logEl.scrollHeight;
  });
</script>

{#if wizard.step !== "closed" && !wizard.embedded}
  <div
    class="scrim"
    role="presentation"
    onclick={() => wizard.close()}
  >
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
    <div class="card" role="dialog" aria-modal="true" aria-label="Engine setup" tabindex="-1" onclick={(e) => e.stopPropagation()}>
      <button type="button" class="close" aria-label="Skip setup" onclick={() => wizard.close()}>
        <X weight="bold" size={15} />
      </button>

      {#if wizard.step === "choose"}
        <h2>Connect an engine</h2>
        <p class="lede">
          Workbooks runs offline on its own. Connect an engine to run agents,
          compile code, and sync. You can do this later from the titlebar.
        </p>
        <div class="choices">
          <button type="button" class="choice" onclick={() => wizard.chooseLocal()}>
            <Cpu weight="fill" size={20} />
            <span class="ct">Run on this machine</span>
            <span class="cd">A sandboxed microVM, fully local. macOS.</span>
          </button>
          <button type="button" class="choice" onclick={() => wizard.chooseCloud()}>
            <Cloud weight="fill" size={20} />
            <span class="ct">Connect to a cloud engine</span>
            <span class="cd">Point at a hosted engine by URL.</span>
          </button>
        </div>
        {#if wizard.error}<p class="err"><AlertCircle weight="fill" size={13} /> {wizard.error}</p>{/if}

      {:else if wizard.step === "local-detect"}
        <h2>Checking this machine…</h2>
        <p class="lede center"><Loader weight="bold" size={18} class="spin" /> Looking for the VM backend.</p>

      {:else if wizard.step === "local-install"}
        <h2>Install the VM backend</h2>
        <p class="lede">
          Running the engine locally needs <code>krunvm</code> (a lightweight
          microVM tool). We can install it with Homebrew.
        </p>
        {#if wizard.backend && !wizard.backend.brew}
          <p class="err">
            <AlertCircle weight="fill" size={13} /> Homebrew isn't installed. Get it at
            <code>brew.sh</code>, or run
            <code>brew tap slp/krun &amp;&amp; brew install krunvm</code> yourself, then retry.
          </p>
        {/if}
        {#if wizard.log.length}
          <div class="log" bind:this={logEl}>
            {#each wizard.log as line}<div class="ll">{line}</div>{/each}
          </div>
        {/if}
        {#if wizard.error}<p class="err"><AlertCircle weight="fill" size={13} /> {wizard.error}</p>{/if}
        <div class="actions">
          <button type="button" class="btn ghost" onclick={() => wizard.retry()}>Back</button>
          <button
            type="button"
            class="btn primary"
            disabled={wizard.busy || (wizard.backend ? !wizard.backend.brew : false)}
            onclick={() => wizard.installBackend()}
          >
            <Download weight="fill" size={14} />
            {wizard.busy ? "Installing…" : "Install krunvm"}
          </button>
        </div>

      {:else if wizard.step === "local-booting"}
        <h2>Starting the engine</h2>
        <p class="lede center">
          <Loader weight="bold" size={18} class="spin" /> Booting a microVM. The first run
          downloads the engine image — this is slow once, then cached.
        </p>
        {#if wizard.pull?.total}
          {@const pct = Math.min(100, Math.round((wizard.pull.done / wizard.pull.total) * 100))}
          <div class="pull-bar"><div class="pull-fill" style="width: {pct}%"></div></div>
          <p class="pull-label">{pct}% · {(wizard.pull.done / 1048576).toFixed(0)} / {(wizard.pull.total / 1048576).toFixed(0)} MB</p>
        {/if}
        <div class="log" bind:this={logEl}>
          {#each wizard.log as line}<div class="ll">{line}</div>{/each}
          {#if !wizard.log.length}<div class="ll dim">working…</div>{/if}
        </div>
        {#if wizard.error}
          <p class="err"><AlertCircle weight="fill" size={13} /> {wizard.error}</p>
          <div class="actions">
            <button type="button" class="btn ghost" onclick={() => wizard.retry()}>Back</button>
            <button type="button" class="btn primary" onclick={() => wizard.bootLocal()}>
              <RefreshCw weight="fill" size={14} /> Retry
            </button>
          </div>
        {/if}

      {:else if wizard.step === "cloud-form"}
        <h2>Connect to a cloud engine</h2>
        <p class="lede">Paste the engine URL and token. We'll verify it answers before saving.</p>
        <label class="field">
          <span>Engine URL</span>
          <input type="url" placeholder="https://engine.example.com" bind:value={wizard.cloudUrl} />
        </label>
        <label class="field">
          <span>Token <em>(optional)</em></span>
          <input type="password" placeholder="bearer token" bind:value={wizard.cloudToken} />
        </label>
        {#if wizard.error}<p class="err"><AlertCircle weight="fill" size={13} /> {wizard.error}</p>{/if}
        <div class="actions">
          <button type="button" class="btn ghost" onclick={() => wizard.retry()}>Back</button>
          <button type="button" class="btn primary" disabled={wizard.busy} onclick={() => wizard.connectCloud()}>
            Connect
          </button>
        </div>

      {:else if wizard.step === "cloud-connecting"}
        <h2>Connecting…</h2>
        <p class="lede center"><Loader weight="bold" size={18} class="spin" /> Probing the engine.</p>

      {:else if wizard.step === "done"}
        <div class="done">
          <span class="check"><Check weight="bold" size={26} /></span>
          <h2>Engine connected</h2>
          <p class="lede center">You're all set.</p>
        </div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .scrim {
    position: fixed;
    inset: 0;
    z-index: 1100;
    background: color-mix(in srgb, var(--color-page) 55%, transparent);
    backdrop-filter: blur(3px);
    display: grid;
    place-items: center;
  }
  .card {
    position: relative;
    width: min(440px, calc(100vw - 2rem));
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 14px;
    box-shadow: 0 20px 60px rgba(15, 23, 42, 0.18);
    padding: 1.6rem 1.6rem 1.4rem;
  }
  .close {
    position: absolute;
    top: 0.7rem;
    right: 0.7rem;
    display: inline-flex;
    padding: 5px;
    border: 0;
    border-radius: 7px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
  }
  .close:hover { background: var(--color-page); color: var(--color-fg); }

  h2 {
    margin: 0 0 0.4rem;
    font-size: 1.05rem;
    font-weight: 600;
    color: var(--color-fg);
  }
  .lede {
    margin: 0 0 1rem;
    font-size: 0.85rem;
    line-height: 1.45;
    color: var(--color-fg-muted);
  }
  .lede.center {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    justify-content: center;
    padding: 0.6rem 0;
  }
  code {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.8em;
    background: var(--color-page);
    padding: 1px 5px;
    border-radius: 4px;
  }

  .choices { display: grid; gap: 0.6rem; }
  .choice {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-template-rows: auto auto;
    column-gap: 0.75rem;
    text-align: left;
    padding: 0.85rem 1rem;
    border: 1px solid var(--color-border);
    border-radius: 10px;
    background: var(--color-page);
    cursor: pointer;
    transition: border-color 0.12s, transform 0.12s;
  }
  .choice :global(svg) { grid-row: 1 / 3; align-self: center; color: var(--color-brand, #149157); }
  .choice:hover { border-color: var(--color-brand, #149157); transform: translateY(-1px); }
  .ct { font-size: 0.9rem; font-weight: 600; color: var(--color-fg); }
  .cd { font-size: 0.78rem; color: var(--color-fg-subtle); }

  .field { display: grid; gap: 0.3rem; margin-bottom: 0.8rem; }
  .field span { font-size: 0.78rem; font-weight: 500; color: var(--color-fg-muted); }
  .field em { font-style: normal; color: var(--color-fg-subtle); font-weight: 400; }
  .field input {
    padding: 0.5rem 0.65rem;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-page);
    color: var(--color-fg);
    font-size: 0.85rem;
    font-family: inherit;
  }
  .field input:focus {
    outline: none;
    border-color: var(--color-brand, #149157);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-brand, #149157) 18%, transparent);
  }

  .log {
    max-height: 150px;
    overflow-y: auto;
    margin: 0.2rem 0 0.9rem;
    padding: 0.55rem 0.7rem;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-page);
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.72rem;
    line-height: 1.5;
    color: var(--color-fg-muted);
  }
  .ll { white-space: pre-wrap; word-break: break-word; }
  .ll.dim { color: var(--color-fg-subtle); }

  .actions { display: flex; justify-content: flex-end; gap: 0.5rem; }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 0.5rem 1rem;
    border-radius: 8px;
    font-size: 0.83rem;
    font-weight: 600;
    font-family: inherit;
    cursor: pointer;
    border: 1px solid transparent;
  }
  .btn.primary {
    background: var(--color-brand, #149157);
    color: #fff;
    border-color: var(--color-brand, #149157);
  }
  .btn.primary:hover:not(:disabled) { filter: brightness(1.05); }
  .btn.ghost { background: transparent; border-color: var(--color-border); color: var(--color-fg-muted); }
  .btn.ghost:hover { color: var(--color-fg); border-color: var(--color-border-strong); }
  .btn:disabled { opacity: 0.55; cursor: not-allowed; }

  .err {
    display: flex;
    align-items: flex-start;
    gap: 0.4rem;
    margin: 0 0 0.9rem;
    font-size: 0.78rem;
    line-height: 1.45;
    color: var(--color-danger, #d23f3f);
  }
  .err :global(svg) { flex-shrink: 0; margin-top: 2px; }

  .done { text-align: center; padding: 0.6rem 0 0.3rem; }
  .check {
    display: inline-grid;
    place-items: center;
    width: 52px;
    height: 52px;
    margin-bottom: 0.5rem;
    border-radius: 50%;
    background: color-mix(in srgb, var(--color-ok, #16a34a) 16%, transparent);
    color: var(--color-ok, #16a34a);
  }

  :global(.spin) { animation: wiz-spin 900ms linear infinite; }
  @keyframes wiz-spin { to { transform: rotate(360deg); } }
  .pull-bar {
    height: 6px;
    border-radius: 999px;
    background: var(--color-surface-soft);
    overflow: hidden;
    margin-bottom: 4px;
  }
  .pull-fill {
    height: 100%;
    border-radius: 999px;
    background: var(--color-brand);
    transition: width 0.6s ease;
  }
  .pull-label {
    margin: 0 0 6px;
    font-family: ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
    text-align: center;
  }
</style>
