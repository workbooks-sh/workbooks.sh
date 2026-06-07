<script lang="ts">
  /**
   * DetectModal — connect flow for local-CLI integrations
   * (Claude Code, Codex, Google Workspace `gws`).
   *
   * The "connect" surface for these isn't a paste field — it's a
   * detect-on-PATH probe. We invoke the Rust-side
   * `connections_detect_local_cli` which runs `<binary> --version`
   * with a 3s timeout, then offer a single "Connect" action that
   * persists the resolved path so the agent can shell to it.
   *
   * States:
   *   - probing: spinner + "Looking for `<binary>` on your PATH…"
   *   - found:   path + version + Connect button
   *   - missing: install instructions + Detect-again button
   *   - error:   binary exists but `--version` blew up; show the error
   */
  import { invoke } from "@tauri-apps/api/core";
  import {
    Check,
    Loader2,
    ExternalLink,
    AlertCircle,
    SearchCheck,
    Download,
  } from "@lucide/svelte";
  import { connections } from "$lib/bridge/connections.svelte";
  import type { ConnectionService } from "$lib/bridge/connections.svelte";
  import { terminalDrawer } from "$lib/bridge/terminal.svelte";

  let {
    serviceId,
    serviceName,
    serviceLogo,
    binaryName,
    installCommand,
    installUrl,
    signInScript,
    oncancel,
    onconnected,
  }: {
    serviceId: ConnectionService;
    serviceName: string;
    serviceLogo: string;
    /** The binary the agent will shell to (`claude`, `codex`, `gws`). */
    binaryName: string;
    /** Copy-pastable install command shown when not detected. */
    installCommand: string;
    /** Link out to the service's official install instructions. */
    installUrl: string;
    /** When set, "Connect" runs this script in the terminal drawer
     *  (install missing prereqs + interactive sign-in) and only marks
     *  the connection as ready after it exits 0. Services without a
     *  script (or without a sign-in step) persist the connection
     *  immediately on Connect. */
    signInScript?: string;
    oncancel: () => void;
    onconnected: () => void;
  } = $props();

  type Probe = {
    found: boolean;
    path: string | null;
    version: string | null;
    error: string | null;
  };

  let probe = $state<Probe | null>(null);
  let probing = $state(false);
  let connecting = $state(false);
  let connectError = $state<string | null>(null);
  let cardEl: HTMLDivElement | undefined = $state();

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    if (!connecting) oncancel();
  }
  function key(e: KeyboardEvent) {
    if (e.key === "Escape" && !connecting) oncancel();
  }

  async function runProbe() {
    probing = true;
    connectError = null;
    try {
      probe = await invoke<Probe>("connections_detect_local_cli", {
        name: binaryName,
      });
    } catch (e) {
      probe = {
        found: false,
        path: null,
        version: null,
        error: e instanceof Error ? e.message : String(e),
      };
    } finally {
      probing = false;
    }
  }

  // Fire the initial probe once when the modal mounts.
  let bootstrapped = false;
  $effect(() => {
    if (bootstrapped) return;
    bootstrapped = true;
    runProbe();
  });

  /** `claude --version` returns "2.1.150 (Claude Code)", `gws` returns
   *  things like "gws 0.4.0 (built abc123)". Strip parenthetical
   *  suffixes and obvious binary-name prefixes so the card subtitle
   *  reads as just the version digits. */
  function cleanVersion(raw: string | null): string | null {
    if (!raw) return null;
    let v = raw.replace(/\([^)]*\)\s*$/, "").trim();
    // If it starts with the binary name + space, strip that too.
    const namePrefix = new RegExp(`^${binaryName}\\s+`, "i");
    v = v.replace(namePrefix, "").trim();
    return v.length > 0 ? v : null;
  }

  async function connect() {
    if (!probe?.path) return;

    // Path A — service has a sign-in script (Google Workspace etc).
    // Fire off the script in the terminal drawer, dismiss the modal
    // IMMEDIATELY so the user can interact with the drawer (read
    // logs, type into prompts, etc), and persist the connection in
    // the background once the script exits 0. The card stays in
    // "Connect" state until persistence completes, so a partial
    // setup never reads as connected.
    if (signInScript) {
      const path = probe.path;
      const version = cleanVersion(probe.version);

      // Detached background flow — the promise lives past this
      // component's unmount. `terminalDrawer` is a singleton store,
      // so its run/resolve plumbing isn't tied to our lifecycle.
      void (async () => {
        try {
          const result = await terminalDrawer.runInstall({
            command: ["bash", "-c", signInScript],
            label: `Setting up ${serviceName}`,
          });
          if (result.exit_code === 0) {
            await invoke("connections_create_local_cli", {
              req: { service: serviceId, path, version },
            });
            await connections.refresh();
          }
          // On non-zero exit, the terminal output already explains
          // the failure. We don't persist; the card stays at
          // "Connect" so the user can try again from a clean state.
        } catch (e) {
          console.warn(`[detect-modal] background setup for ${serviceId}:`, e);
        }
      })();

      // Close the modal right away. `runInstall` already opened the
      // drawer synchronously, so by the time the modal unmounts the
      // user can already see + interact with the running session.
      onconnected();
      return;
    }

    // Path B — no setup script. Persist immediately on Connect
    // (original behavior for simpler local-CLI integrations).
    connecting = true;
    connectError = null;
    try {
      await invoke("connections_create_local_cli", {
        req: {
          service: serviceId,
          path: probe.path,
          version: cleanVersion(probe.version),
        },
      });
      await connections.refresh();
      onconnected();
    } catch (e) {
      connectError = e instanceof Error ? e.message : String(e);
    } finally {
      connecting = false;
    }
  }

  async function copyInstall() {
    try {
      await navigator.clipboard.writeText(installCommand);
    } catch {
      // Best-effort — fall through silently if clipboard write fails.
    }
  }

  // Parse `installCommand` into argv the way a shell would. Naive
  // (no quote handling); the install commands we ship are all simple
  // single-word args so this works.
  function parseArgv(cmd: string): string[] {
    return cmd.split(/\s+/).filter(Boolean);
  }

  let installRunning = $state(false);
  let installError = $state<string | null>(null);

  async function runInstall() {
    if (installRunning) return;
    installRunning = true;
    installError = null;
    try {
      const result = await terminalDrawer.runInstall({
        command: parseArgv(installCommand),
        label: `Installing ${binaryName}`,
      });
      if (result.exit_code === 0) {
        // Re-detect — if it worked, the empty state flips to "Found".
        await runProbe();
      } else {
        installError = `Install exited ${result.exit_code ?? "unexpectedly"}. Check the terminal for details.`;
      }
    } catch (e) {
      installError = e instanceof Error ? e.message : String(e);
    } finally {
      installRunning = false;
    }
  }
</script>

<svelte:window onkeydown={key} />

<div class="backdrop" onmousedown={backdrop} role="presentation">
  <div class="card" bind:this={cardEl}>
    <header class="head">
      <div class="logo" aria-hidden="true">{@html serviceLogo}</div>
      <div class="head-text">
        <h3>Connect {serviceName}</h3>
        <p class="sub">
          {#if signInScript}
            We'll detect or install
            <code>{binaryName}</code>, then run {serviceName}'s OAuth
            flow in the in-app terminal — your browser will open for
            sign-in. You'll be marked connected only after that
            completes.
          {:else}
            We'll look for the
            <code>{binaryName}</code>
            binary on your PATH. The agent shells to it for everything
            {serviceName}-related — your credentials stay with the CLI.
          {/if}
        </p>
      </div>
    </header>

    {#if probing}
      <div class="state loading">
        <Loader2 size={16} strokeWidth={2} class="spin" />
        <span>Looking for <code>{binaryName}</code> on your PATH…</span>
      </div>
    {:else if probe?.found && probe.path && !probe.error}
      <div class="state ok">
        <SearchCheck size={16} strokeWidth={2} />
        <div class="state-body">
          <p class="state-title">Found it.</p>
          <dl class="probe-meta">
            <dt>Path</dt>
            <dd><code>{probe.path}</code></dd>
            {#if probe.version}
              <dt>Version</dt>
              <dd><code>{probe.version}</code></dd>
            {/if}
          </dl>
        </div>
      </div>
    {:else if probe && probe.found && probe.error}
      <div class="state warn" role="alert">
        <AlertCircle size={16} strokeWidth={2} />
        <div class="state-body">
          <p class="state-title">
            Found <code>{binaryName}</code>, but it didn't respond.
          </p>
          <p class="state-msg">{probe.error}</p>
          {#if probe.path}
            <p class="state-msg muted">
              Resolved path: <code>{probe.path}</code>
            </p>
          {/if}
        </div>
      </div>
    {:else}
      <div class="state empty">
        <p class="state-title">
          <code>{binaryName}</code> isn't installed on this machine.
        </p>
        <p class="state-msg">
          Install it from here — we'll run it in the terminal drawer
          so you can see what's happening:
        </p>
        <div class="install-row">
          <code class="install-cmd">{installCommand}</code>
          <button
            type="button"
            class="copy-btn"
            onclick={copyInstall}
            title="Copy install command"
          >
            Copy
          </button>
        </div>
        <div class="install-actions">
          <button
            type="button"
            class="btn primary"
            onclick={runInstall}
            disabled={installRunning}
          >
            {#if installRunning}
              <Loader2 size={12} strokeWidth={2} class="spin" /> Installing…
            {:else}
              <Download size={12} strokeWidth={1.8} /> Install for me
            {/if}
          </button>
        </div>
        {#if installError}
          <p class="install-error">{installError}</p>
        {/if}
        <a
          href={installUrl}
          target="_blank"
          rel="noopener noreferrer"
          class="dash-link"
        >
          {serviceName} install docs <ExternalLink
            size={11}
            strokeWidth={2}
          />
        </a>
      </div>
    {/if}

    {#if connectError}
      <div class="err">{connectError}</div>
    {/if}

    <footer class="foot">
      <button
        type="button"
        class="btn ghost"
        onclick={oncancel}
        disabled={connecting}
      >
        Cancel
      </button>
      {#if probe?.found && probe.path && !probe.error}
        <button
          type="button"
          class="btn primary"
          onclick={connect}
          disabled={connecting}
        >
          {#if connecting}
            <Loader2 size={13} strokeWidth={2} class="spin" />
            {signInScript ? "Setting up…" : "Connecting…"}
          {:else if signInScript}
            <Check size={13} strokeWidth={2.4} /> Connect & sign in
          {:else}
            <Check size={13} strokeWidth={2.4} /> Connect
          {/if}
        </button>
      {:else}
        <button
          type="button"
          class="btn primary"
          onclick={runProbe}
          disabled={probing}
        >
          {probing ? "Detecting…" : "Detect again"}
        </button>
      {/if}
    </footer>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.32);
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }
  .card {
    width: 100%;
    max-width: 460px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.25rem 1.25rem 1rem;
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
  }
  .head {
    display: flex;
    gap: 0.7rem;
    align-items: flex-start;
  }
  .logo {
    width: 28px;
    height: 28px;
    color: var(--color-fg);
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .logo :global(svg) {
    width: 100%;
    height: 100%;
  }
  h3 {
    margin: 0 0 0.2rem;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.005em;
  }
  .sub {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    line-height: 1.45;
  }
  .sub code,
  .install-cmd,
  .probe-meta code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.78em;
  }

  .state {
    display: flex;
    gap: 0.65rem;
    align-items: flex-start;
    padding: 0.9rem 0.85rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
    line-height: 1.45;
  }
  .state.ok {
    color: var(--color-fg);
    border-color: color-mix(
      in srgb,
      var(--color-emerald, #10b981) 35%,
      var(--color-border)
    );
  }
  .state.warn { color: #f59e0b; }
  .state.empty {
    flex-direction: column;
    align-items: stretch;
    color: var(--color-fg);
  }
  .state-body { flex: 1 1 auto; min-width: 0; }
  .state-title {
    margin: 0 0 0.25rem;
    font-weight: 500;
    color: var(--color-fg);
  }
  .state-msg {
    margin: 0;
    color: var(--color-fg-muted);
  }
  .state-msg.muted { font-size: 0.74rem; }

  /* Path + version dl pair — keep tight. */
  .probe-meta {
    display: grid;
    grid-template-columns: 60px 1fr;
    gap: 0.2rem 0.65rem;
    margin: 0.3rem 0 0;
    font-size: 0.78rem;
  }
  .probe-meta dt {
    color: var(--color-fg-subtle);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 0.7rem;
    align-self: center;
  }
  .probe-meta dd {
    margin: 0;
    color: var(--color-fg);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .install-row {
    display: flex;
    gap: 0.4rem;
    align-items: stretch;
    margin-top: 0.4rem;
  }
  .install-cmd {
    flex: 1 1 auto;
    background: var(--color-page);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    padding: 0.45rem 0.6rem;
    color: var(--color-fg);
    overflow-x: auto;
    white-space: nowrap;
  }
  .copy-btn {
    flex-shrink: 0;
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.74rem;
    padding: 0 0.65rem;
    cursor: pointer;
    transition: background 0.1s, color 0.1s;
  }
  .copy-btn:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  /* Action row that hosts the "Install for me" button. */
  .install-actions {
    display: flex;
    gap: 0.4rem;
    margin-top: 0.4rem;
  }
  .install-error {
    margin: 0.4rem 0 0;
    color: #ef4444;
    font-size: 0.74rem;
    line-height: 1.4;
    word-break: break-word;
  }
  .dash-link {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    margin-top: 0.55rem;
    color: var(--color-fg-muted);
    text-decoration: none;
    font-size: 0.78rem;
  }
  .dash-link:hover { color: var(--color-fg); }

  .err {
    font-size: 0.76rem;
    color: #ef4444;
    word-break: break-word;
  }

  .foot {
    display: flex;
    gap: 0.4rem;
    justify-content: flex-end;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 30px;
    padding: 0 0.85rem;
    border-radius: 7px;
    font-size: 0.82rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    border: 0;
    transition: opacity 0.1s, background 0.1s;
  }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn.primary { background: var(--color-fg); color: var(--color-page); }
  .btn.primary:hover:not(:disabled) { opacity: 0.88; }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border: 1px solid var(--color-border);
  }
  .btn.ghost:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  :global(.spin) {
    animation: spin 0.9s linear infinite;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }
</style>
