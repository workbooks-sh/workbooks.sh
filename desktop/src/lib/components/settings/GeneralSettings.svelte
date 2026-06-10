<script lang="ts">
  import { enginePath } from "$lib/engine-api/gen";
  /**
   * GeneralSettings — the landing surface of Settings.
   *
   * Two things, no more:
   *
   *   1. A single identity card that fuses the Workbooks account
   *      (email, sign-in) with the network identity (handle, DID,
   *      key) — they're one *you* to the user, even though the
   *      substrate keeps them in separate stores.
   *
   *   2. A live log stream from the engine. The previous
   *      incarnation buried this behind a "▸ Event tail (6)"
   *      disclosure plus a developer-only "send a user-input
   *      event" composer; both gone. Logs are the primary thing
   *      a user cares about on this page.
   *
   * The engine status itself (Ready / Starting / …) sits as a
   * single pill in the page corner, and the URL + build/version
   * line is a small footer under the identity card. Both are
   * informational but not the protagonist.
   */

  import { onMount } from "svelte";
  import { SignIn as LogIn, SignOut as LogOut, ArrowsClockwise as RefreshCw } from "phosphor-svelte";
  import { sidecar, type SidecarState } from "$lib/bridge/sidecar.svelte";
  import { ws } from "$lib/bridge/ws.svelte";
  import { auth } from "$lib/auth/store.svelte";
  import { loadIdentity, type IdentityView } from "$lib/bridge/network.svelte";

  let identity = $state<IdentityView | null>(null);
  let identityLoading = $state(false);
  let actionError = $state<string | null>(null);
  let busy = $state(false);

  type About = {
    version: string;
    git_sha: string;
    built_at: string;
    boot_at: string;
    uptime_ms: number;
    route_count: number;
  };
  let about = $state<About | null>(null);

  onMount(async () => {
    sidecar.init();
    ws.init();
    identityLoading = true;
    try {
      identity = await loadIdentity();
    } catch {
      identity = null;
    } finally {
      identityLoading = false;
    }
  });

  // Refetch /api/about whenever the engine becomes ready or its URL changes.
  $effect(() => {
    const url = sidecar.status.url;
    const state = sidecar.status.state;
    if (!url || state !== "ready") {
      about = null;
      return;
    }
    fetch(`${url}${enginePath.about}`)
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => (about = data))
      .catch(() => (about = null));
  });

  // ── identity helpers ───────────────────────────────────────────────

  const displayName = $derived(
    auth.user?.displayName?.trim() ||
      identity?.handle ||
      auth.user?.email?.split("@")[0] ||
      null,
  );
  const handle = $derived(identity?.handle ?? null);
  const didShort = $derived(formatDid(identity?.did));
  const keyShort = $derived(formatKey(identity?.public_key_b64));

  function formatDid(did: string | undefined): string | null {
    if (!did) return null;
    // did:web:example.com:user:abc123…long → did:web:…last8
    if (did.length <= 22) return did;
    return `${did.slice(0, 8)}…${did.slice(-8)}`;
  }
  function formatKey(b64: string | undefined): string | null {
    if (!b64) return null;
    return `${b64.slice(0, 6)}…${b64.slice(-4)}`;
  }

  async function signIn() {
    if (busy) return;
    busy = true;
    actionError = null;
    try {
      await auth.signIn();
    } catch (e) {
      actionError = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }
  async function signOut() {
    if (busy) return;
    busy = true;
    actionError = null;
    try {
      await auth.signOut();
    } catch (e) {
      actionError = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }
  async function refreshSession() {
    if (busy) return;
    busy = true;
    actionError = null;
    try {
      await auth.refresh();
    } catch (e) {
      actionError = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  // ── engine status helpers ──────────────────────────────────────────

  const STATE_TONE: Record<SidecarState, "ok" | "warn" | "err" | "muted"> = {
    starting: "warn",
    ready: "ok",
    unhealthy: "warn",
    crashed: "err",
    restarting: "warn",
    stopped: "muted",
  };
  const STATE_LABEL: Record<SidecarState, string> = {
    starting: "Starting",
    ready: "Ready",
    unhealthy: "Unhealthy",
    crashed: "Crashed",
    restarting: "Restarting",
    stopped: "Stopped",
  };

  function shortStamp(iso: string | undefined): string {
    if (!iso) return "—";
    try {
      const d = new Date(iso);
      return d.toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      });
    } catch {
      return iso;
    }
  }

  // ── logs ──────────────────────────────────────────────────────────

  /** Most-recent first, formatted for the log stream. The key
   *  includes the source array index because `BridgeEvent` has
   *  no inherent id — two events with the same name + ms-precision
   *  receivedAt (e.g. a burst of `bridge:joined` from rapid
   *  channel rejoins) would otherwise collide. ws.events is
   *  append-only, so the index is stable for the row's lifetime. */
  const logRows = $derived(
    ws.events
      .map((e, i) => ({
        // Index first so the key is unique even when name/time match.
        key: `${i}-${e.name}-${e.receivedAt}`,
        time: new Date(e.receivedAt).toLocaleTimeString(undefined, {
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
          hour12: false,
        }),
        name: e.name,
        topic: e.topic,
      }))
      .reverse()
      .slice(0, 200),
  );

  // Optional initial — first character of name / handle / email, uppercased.
  const initial = $derived(
    (displayName ?? auth.user?.email ?? "?").trim().slice(0, 1).toUpperCase(),
  );
</script>

<div class="general">
  <header class="head">
    <span class="status status-{STATE_TONE[sidecar.status.state]}">
      <span class="dot"></span>
      {STATE_LABEL[sidecar.status.state]}
    </span>
  </header>

  <!-- Identity card: account + network identity, fused. -->
  <section class="identity" class:signed-out={auth.status === "signed-out"}>
    {#if auth.status === "checking"}
      <p class="muted center">Checking your session…</p>
    {:else if auth.status === "signed-in" && auth.user}
      <div class="who">
        {#if auth.user.picture}
          <img
            class="avatar avatar-img"
            src={auth.user.picture}
            alt=""
            referrerpolicy="no-referrer"
            onerror={(e) => {
              // WorkOS CDN URLs occasionally 404 (user deleted, CDN
              // hiccup). Hide the broken image so the layout doesn't
              // show the alt-text outline; CSS shows the initial-only
              // fallback in the sibling div instead.
              (e.currentTarget as HTMLImageElement).style.display = "none";
              const fallback = (e.currentTarget as HTMLImageElement)
                .nextElementSibling as HTMLElement | null;
              if (fallback) fallback.style.display = "grid";
            }}
          />
          <div class="avatar avatar-initial" aria-hidden="true" style="display:none">{initial}</div>
        {:else}
          <div class="avatar avatar-initial" aria-hidden="true">{initial}</div>
        {/if}
        <div class="who-text">
          <div class="name">{displayName}</div>
          <div class="email">{auth.user.email}</div>
        </div>
        <div class="who-actions">
          <button type="button" class="ghost" onclick={refreshSession} disabled={busy} title="Refresh session">
            <RefreshCw weight="fill" size={13} />
          </button>
          <button type="button" class="ghost danger" onclick={signOut} disabled={busy} title="Sign out">
            <LogOut weight="fill" size={13} />
          </button>
        </div>
      </div>

      {#if handle || didShort || keyShort}
        <div class="net">
          {#if handle}<span class="net-cell"><span class="net-label">handle</span><span class="net-val">@{handle}</span></span>{/if}
          {#if didShort}<span class="net-cell"><span class="net-label">did</span><code class="net-val mono">{didShort}</code></span>{/if}
          {#if keyShort}<span class="net-cell"><span class="net-label">key</span><code class="net-val mono">{keyShort}</code></span>{/if}
        </div>
      {/if}
    {:else if auth.status === "signed-out"}
      <div class="signed-out-body">
        <p class="lede">Sign in to publish workbooks, message friends, and sync across devices.</p>
        <button type="button" class="primary" onclick={signIn} disabled={busy}>
          <LogIn weight="fill" size={14} />
          {busy ? "Opening sign-in…" : "Sign in to Workbooks"}
        </button>
      </div>
    {:else}
      <p class="muted center err">
        The engine isn't running — restart the app to recover.
      </p>
    {/if}

    {#if actionError}
      <p class="action-err">{actionError}</p>
    {/if}
  </section>

  <!-- Engine version footer — informational, intentionally quiet. -->
  <footer class="engine-foot">
    {#if about}
      <code class="mono">v{about.version}</code>
      <span class="sep">·</span>
      <code class="mono">{about.git_sha}</code>
      <span class="sep">·</span>
      <span>built {shortStamp(about.built_at)}</span>
      {#if sidecar.status.url}
        <span class="sep">·</span>
        <code class="mono">{sidecar.status.url}</code>
      {/if}
    {:else if sidecar.status.url}
      <code class="mono">{sidecar.status.url}</code>
    {:else}
      <span>engine not reachable</span>
    {/if}
  </footer>

  <!-- Logs: the protagonist of this page. -->
  <section class="logs">
    <header class="logs-head">
      <h2>Logs</h2>
      <span class="logs-count">{ws.events.length} {ws.events.length === 1 ? "event" : "events"}</span>
    </header>

    {#if ws.lastError}
      <p class="logs-err">connection error · {ws.lastError}</p>
    {/if}

    {#if logRows.length === 0}
      <p class="logs-empty">No events yet. They'll stream in as the engine runs sessions, tool calls, and lifecycle events.</p>
    {:else}
      <ol class="log-list">
        {#each logRows as row (row.key)}
          <li>
            <span class="log-time">{row.time}</span>
            <code class="log-name">{row.name}</code>
            <span class="log-topic">{row.topic}</span>
          </li>
        {/each}
      </ol>
    {/if}
  </section>
</div>

<style>
  .general {
    display: flex;
    flex-direction: column;
    gap: 1.4rem;
    max-width: 640px;
    width: 100%;
    margin: 0 auto;
  }

  /* ── page head ─────────────────────────────────────────────── */
  .head {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 1rem;
    min-height: 1.4rem;
  }
  .status {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.75rem;
    color: var(--color-fg-muted);
    letter-spacing: 0.02em;
  }
  .status .dot {
    width: 7px;
    height: 7px;
    border-radius: 999px;
    background: var(--color-fg-subtle);
  }
  .status-ok .dot { background: rgb(52, 195, 143); }
  .status-warn .dot { background: rgb(232, 167, 56); }
  .status-err .dot { background: rgb(220, 92, 92); }

  /* ── identity card ─────────────────────────────────────────── */
  .identity {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 14px;
    padding: 1.1rem 1.2rem;
    display: flex;
    flex-direction: column;
    gap: 0.95rem;
  }
  .identity.signed-out {
    background: transparent;
    border-style: dashed;
  }
  .who {
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: center;
    gap: 0.9rem;
  }
  .avatar {
    width: 44px;
    height: 44px;
    border-radius: 999px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    display: grid;
    place-items: center;
    font-size: 1.05rem;
    font-weight: 600;
    color: var(--color-fg);
    letter-spacing: 0;
  }
  .avatar-img {
    object-fit: cover;
    /* Reset grid display from .avatar — img doesn't need it. */
    display: block;
  }
  .name {
    font-size: 0.96rem;
    font-weight: 600;
    letter-spacing: -0.01em;
    color: var(--color-fg);
  }
  .email {
    font-size: 0.8rem;
    color: var(--color-fg-muted);
    margin-top: 0.1rem;
  }
  .who-actions {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
  }
  .net {
    display: flex;
    flex-wrap: wrap;
    gap: 0 1.4rem;
    padding-top: 0.85rem;
    border-top: 1px solid var(--color-border);
    row-gap: 0.4rem;
  }
  .net-cell {
    display: inline-flex;
    align-items: baseline;
    gap: 0.5rem;
  }
  .net-label {
    font-size: 0.7rem;
    color: var(--color-fg-subtle);
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  .net-val {
    font-size: 0.82rem;
    color: var(--color-fg);
  }
  .mono {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }

  /* ── signed-out state ──────────────────────────────────────── */
  .signed-out-body {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 0.9rem;
    padding: 0.4rem 0;
  }
  .lede {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.86rem;
    line-height: 1.55;
  }

  /* ── buttons ───────────────────────────────────────────────── */
  .ghost,
  .primary {
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    border-radius: 6px;
    font: inherit;
    font-size: 0.82rem;
    font-weight: 500;
    cursor: pointer;
    padding: 0.4rem 0.6rem;
    background: transparent;
    color: var(--color-fg-muted);
    border: 1px solid transparent;
    transition: color 0.1s, background 0.1s, border-color 0.1s;
  }
  .ghost:hover:not(:disabled) {
    color: var(--color-fg);
    background: var(--color-surface-soft);
  }
  .ghost.danger:hover:not(:disabled) {
    color: rgb(220, 92, 92);
  }
  .ghost:disabled,
  .primary:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
  .primary {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: var(--color-fg);
    padding: 0.5rem 0.9rem;
    font-weight: 600;
    font-size: 0.83rem;
  }
  .primary:hover:not(:disabled) {
    opacity: 0.9;
  }

  /* ── engine footer ─────────────────────────────────────────── */
  .engine-foot {
    display: flex;
    flex-wrap: wrap;
    gap: 0.45rem;
    align-items: center;
    font-size: 0.72rem;
    color: var(--color-fg-subtle);
    padding: 0 0.2rem;
    margin-top: -0.5rem;
  }
  .engine-foot .sep {
    opacity: 0.5;
  }
  .engine-foot .mono {
    font-size: 0.72rem;
  }

  /* ── logs ──────────────────────────────────────────────────── */
  .logs {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  .logs-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 1rem;
    padding-bottom: 0.4rem;
    border-bottom: 1px solid var(--color-border);
  }
  .logs-head h2 {
    margin: 0;
    font-size: 0.78rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--color-fg-subtle);
  }
  .logs-count {
    font-size: 0.74rem;
    color: var(--color-fg-subtle);
    font-variant-numeric: tabular-nums;
  }
  .logs-err {
    margin: 0;
    color: rgb(220, 92, 92);
    font-size: 0.78rem;
  }
  .logs-empty {
    margin: 0.4rem 0;
    color: var(--color-fg-subtle);
    font-size: 0.82rem;
    font-style: italic;
    line-height: 1.55;
  }
  .log-list {
    list-style: none;
    margin: 0;
    padding: 0;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.78rem;
  }
  .log-list li {
    display: grid;
    grid-template-columns: 5.5rem minmax(0, 14rem) 1fr;
    gap: 0.9rem;
    padding: 0.25rem 0;
    border-bottom: 1px solid color-mix(in oklab, var(--color-border) 50%, transparent);
    align-items: baseline;
  }
  .log-list li:last-child {
    border-bottom: 0;
  }
  .log-time {
    color: var(--color-fg-subtle);
    font-variant-numeric: tabular-nums;
  }
  .log-name {
    color: var(--color-fg);
    font-family: inherit;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .log-topic {
    color: var(--color-fg-subtle);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* ── misc ─────────────────────────────────────────────────── */
  .muted { color: var(--color-fg-muted); font-size: 0.85rem; }
  .center { text-align: center; }
  .err { color: rgb(220, 92, 92); }
  .action-err {
    margin: 0;
    color: rgb(220, 92, 92);
    font-size: 0.78rem;
    padding: 0.4rem 0.6rem;
    background: color-mix(in oklab, rgb(220, 92, 92) 8%, transparent);
    border: 1px solid color-mix(in oklab, rgb(220, 92, 92) 22%, transparent);
    border-radius: 6px;
  }
</style>
