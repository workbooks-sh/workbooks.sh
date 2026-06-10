<script lang="ts">
  /**
   * ComposioPickerModal — "+ Add from Composio" picker.
   *
   * Calls the sidecar's `GET /api/integrations/composio/connections`
   * (which proxies to Composio's REST API with the user's
   * COMPOSIO_API_KEY) and renders each connected account so the user
   * can drop one into the Values list. Picking an account creates an
   * env-var row tagged with `source = { service: "composio", app:
   * <toolkit_slug>, label: "<App> via Composio" }` — the brand-logo
   * column in the values list lights up automatically.
   *
   * v1 uses the Composio brand mark as the source logo for every
   * picked row. Per-app brand logos (Slack, Gmail, …) get fetched
   * from Composio's `/api/v3/toolkits/{slug}` endpoint in a follow-up.
   */
  import { Check, ArrowSquareOut as ExternalLink, WarningCircle as AlertCircle, CircleNotch as Loader2 } from "phosphor-svelte";
  import {
    connections,
    ComposioListError,
    type ComposioAccount,
  } from "$lib/bridge/connections.svelte";
  import { envVars, type EnvScope } from "$lib/bridge/env_vars.svelte";
  import ComposioLogo from "$lib/integrations/logos/composio.svg?raw";

  let {
    scope,
    workspaceId,
    packageName,
    oncancel,
    onpicked,
  }: {
    /** Scope to write the picked rows at. Same shape as the regular
     *  "Add value" flow's scope selector. */
    scope: EnvScope;
    workspaceId?: string | null;
    packageName?: string | null;
    oncancel: () => void;
    onpicked: () => void;
  } = $props();

  let cardEl: HTMLDivElement | undefined = $state();
  let loading = $state(true);
  let accounts = $state<ComposioAccount[]>([]);
  let loadError = $state<{ code: string; message: string } | null>(null);
  /** Per-account "adding…" guard so double-clicks don't write twice. */
  let pickingId = $state<string | null>(null);
  /** Per-account "added ✓" stamp so the row visibly confirms before
   *  the modal closes. */
  let addedId = $state<string | null>(null);

  // Format a slug into a display name: "google_drive" → "Google Drive".
  function prettify(slug: string): string {
    if (!slug) return "Unknown app";
    return slug
      .split(/[_-]/)
      .filter(Boolean)
      .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
      .join(" ");
  }

  function envVarName(slug: string): string {
    // COMPOSIO_<SLUG_UPPER> — the agent uses this to learn that
    // <App> is reachable via the master COMPOSIO_API_KEY.
    return `COMPOSIO_${slug.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`;
  }

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    oncancel();
  }
  function key(e: KeyboardEvent) {
    if (e.key === "Escape" && !pickingId) oncancel();
  }

  async function load() {
    loading = true;
    loadError = null;
    try {
      accounts = await connections.listComposioAccounts();
    } catch (e) {
      if (e instanceof ComposioListError) {
        loadError = { code: e.code, message: e.message };
      } else {
        loadError = {
          code: "unknown",
          message: e instanceof Error ? e.message : String(e),
        };
      }
    } finally {
      loading = false;
    }
  }

  // Initial fetch — fires once when the modal mounts. We don't have
  // an onMount in Svelte 5 runes mode; use $effect with an empty
  // tracker so it runs once.
  let bootstrapped = false;
  $effect(() => {
    if (bootstrapped) return;
    bootstrapped = true;
    load();
  });

  async function pick(account: ComposioAccount) {
    if (pickingId) return;
    pickingId = account.id;
    try {
      await envVars.create({
        name: envVarName(account.toolkit_slug),
        value: account.id,
        scope,
        workspace_id: workspaceId ?? undefined,
        package_name: packageName ?? undefined,
      });
      addedId = account.id;
      // Brief confirmation pulse, then close the modal so the user
      // returns to the values list with the new row visible.
      setTimeout(() => {
        onpicked();
      }, 600);
    } catch (e) {
      loadError = {
        code: "write_failed",
        message: e instanceof Error ? e.message : String(e),
      };
      pickingId = null;
    }
  }
</script>

<svelte:window onkeydown={key} />

<div class="backdrop" onmousedown={backdrop} role="presentation">
  <div class="card" bind:this={cardEl}>
    <header class="head">
      <div class="logo" aria-hidden="true">{@html ComposioLogo}</div>
      <div class="head-text">
        <h3>Add from Composio</h3>
        <p class="sub">
          Pick a connected app to drop into the values list. The agent
          can call it via Composio's SDK using your stored API key.
        </p>
      </div>
    </header>

    {#if loading}
      <div class="state loading">
        <Loader2 weight="bold" size={16} class="spin" />
        <span>Loading your Composio connections…</span>
      </div>
    {:else if loadError}
      <div class="state error" role="alert">
        <AlertCircle weight="fill" size={16} />
        <div>
          <p class="state-title">
            {loadError.code === "no_api_key"
              ? "Composio isn't connected yet."
              : loadError.code === "sidecar_down"
                ? "The agent server isn't running."
                : "Could not reach Composio."}
          </p>
          <p class="state-msg">{loadError.message}</p>
        </div>
      </div>
    {:else if accounts.length === 0}
      <div class="state empty">
        <p class="state-title">No connected apps yet.</p>
        <p class="state-msg">
          Open your Composio dashboard and connect an app there, then
          come back.
        </p>
        <a
          href="https://app.composio.dev/apps"
          target="_blank"
          rel="noopener noreferrer"
          class="dash-link"
        >
          Open Composio <ExternalLink weight="fill" size={11} />
        </a>
      </div>
    {:else}
      <ul class="accounts">
        {#each accounts as account (account.id)}
          {@const added = addedId === account.id}
          {@const picking = pickingId === account.id}
          <li class="account" class:added>
            <div class="meta">
              <span class="app-name">{prettify(account.toolkit_slug)}</span>
              <span class="account-id" title={account.id}>{account.id}</span>
            </div>
            <span class="status status-{account.status.toLowerCase()}">
              {account.status}
            </span>
            <button
              type="button"
              class="add-btn"
              class:added
              disabled={picking || added || pickingId !== null}
              onclick={() => pick(account)}
            >
              {#if added}
                <Check weight="bold" size={12} /> Added
              {:else if picking}
                <Loader2 weight="bold" size={12} class="spin" /> Adding…
              {:else}
                Add
              {/if}
            </button>
          </li>
        {/each}
      </ul>
    {/if}

    <footer class="foot">
      <button
        type="button"
        class="btn ghost"
        onclick={oncancel}
        disabled={pickingId !== null}
      >
        Done
      </button>
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
    max-width: 480px;
    max-height: 80vh;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.25rem 1.25rem 1rem;
    display: flex;
    flex-direction: column;
    min-height: 0;
  }
  .head {
    display: flex;
    gap: 0.7rem;
    align-items: flex-start;
    margin-bottom: 1rem;
    flex-shrink: 0;
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
  .head-text { min-width: 0; }
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

  /* Empty / loading / error states share the same vertical layout. */
  .state {
    display: flex;
    gap: 0.65rem;
    align-items: flex-start;
    padding: 1rem 0.85rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
    line-height: 1.45;
  }
  .state.error { color: #ef4444; }
  .state.empty { flex-direction: column; align-items: center; text-align: center; }
  .state-title { margin: 0 0 0.25rem; font-weight: 500; color: var(--color-fg); }
  .state-msg { margin: 0; }
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

  .accounts {
    list-style: none;
    margin: 0;
    padding: 0;
    overflow-y: auto;
    border: 1px solid var(--color-border);
    border-radius: 8px;
  }
  .account {
    display: flex;
    align-items: center;
    gap: 0.7rem;
    padding: 0.55rem 0.75rem;
    border-bottom: 1px solid var(--color-border);
    transition: background 0.1s;
  }
  .account:last-child { border-bottom: none; }
  .account:hover { background: var(--color-surface-soft); }
  .account.added { background: color-mix(in srgb, var(--color-emerald, #10b981) 8%, transparent); }
  .meta {
    display: flex;
    flex-direction: column;
    flex: 1 1 auto;
    min-width: 0;
  }
  .app-name {
    font-size: 0.86rem;
    color: var(--color-fg);
    font-weight: 500;
  }
  .account-id {
    font-size: 0.7rem;
    color: var(--color-fg-subtle);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .status {
    flex-shrink: 0;
    font-size: 0.66rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 2px 7px;
    border-radius: 999px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-weight: 600;
  }
  .status-active {
    color: var(--color-emerald, #10b981);
    border-color: color-mix(in srgb, var(--color-emerald, #10b981) 40%, var(--color-border));
  }
  .add-btn {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 7px);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.74rem;
    font-weight: 500;
    padding: 0.28rem 0.65rem;
    cursor: pointer;
    transition: background 0.1s, color 0.1s, border-color 0.1s;
  }
  .add-btn:hover:not(:disabled) {
    background: var(--color-surface);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .add-btn:disabled { cursor: default; opacity: 0.6; }
  .add-btn.added {
    color: var(--color-emerald, #10b981);
    border-color: color-mix(in srgb, var(--color-emerald, #10b981) 40%, var(--color-border));
    opacity: 1;
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    margin-top: 0.85rem;
    flex-shrink: 0;
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
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border: 1px solid var(--color-border);
  }
  .btn.ghost:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  /* Tailwind-free spinner — applied via lucide's `class` prop. */
  :global(.spin) {
    animation: spin 0.9s linear infinite;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }
</style>
