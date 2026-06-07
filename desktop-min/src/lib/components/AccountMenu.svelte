<script lang="ts">
  /**
   * AccountMenu — the popover that slides out of the rail account button.
   *
   * Adapts to auth state: header shows the signed-in identity or a muted
   * "Not signed in" lede; a three-row status dashboard (Engine / Account /
   * Network ID) scans the live state at a glance; actions adapt — sign in
   * (+ reset escape hatch when a stale session blocks re-auth) when
   * signed-out, sign out when signed-in, restart engine whenever the
   * engine isn't healthy. Copy never names the underlying auth provider.
   */
  import { LogIn, LogOut, RefreshCw, User as UserIcon } from "@lucide/svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { auth } from "$lib/auth.svelte";

  let { onclose }: { onclose: () => void } = $props();

  function initial(): string {
    const u = auth.user;
    const src = u?.displayName?.trim() || u?.email || "?";
    return src[0].toUpperCase();
  }

  // Status-row helpers — short + scannable.
  const engineRow = $derived.by(() => {
    switch (auth.engineState) {
      case "ok":
        return { label: "Running", dot: "ok" as const };
      case "starting":
        return { label: "Starting…", dot: "pending" as const };
      case "unhealthy":
        return { label: "Unhealthy", dot: "warn" as const };
      default:
        return { label: "Stopped", dot: "err" as const };
    }
  });
  const accountRow = $derived.by(() => {
    if (auth.status === "signed-in") return { label: "Signed in", dot: "ok" as const };
    if (auth.status === "sidecar-offline") return { label: "Unavailable", dot: "warn" as const };
    if (auth.status === "checking") return { label: "Checking…", dot: "pending" as const };
    return { label: "Not signed in", dot: "idle" as const };
  });
  const identityRow = $derived.by(() => {
    if (auth.identity?.handle) return { label: `@${auth.identity.handle}`, dot: "ok" as const };
    if (auth.status === "signed-in") return { label: "Not connected", dot: "idle" as const };
    return { label: "—", dot: "idle" as const };
  });
  const rows = $derived([
    { key: "Engine", ...engineRow },
    { key: "Account", ...accountRow },
    { key: "Network ID", ...identityRow },
  ]);

  async function doSignIn() {
    try {
      onclose();
      await auth.signIn();
    } catch {
      /* lastError surfaced by the store */
    }
  }
  async function doSignOut() {
    onclose();
    await auth.signOut();
  }
  async function doReset() {
    await auth.resetLocalSession();
  }
  async function doRestart() {
    await auth.restartEngine();
  }
</script>

<div
  class="menu"
  role="menu"
  data-account-menu
  transition:fly={{ x: -4, duration: 140, easing: cubicOut }}
>
  <div class="head">
    {#if auth.status === "signed-in"}
      {#if auth.user?.picture}
        <img class="avatar lg" src={auth.user.picture} alt="" referrerpolicy="no-referrer" />
      {:else}
        <span class="avatar lg">{initial()}</span>
      {/if}
      <div class="meta">
        {#if auth.user?.displayName}
          <span class="name">{auth.user.displayName}</span>
        {/if}
        <span class="email">{auth.user?.email}</span>
      </div>
    {:else}
      <span class="avatar lg muted"><UserIcon size={16} strokeWidth={2} /></span>
      <div class="meta">
        <span class="name muted">Not signed in</span>
        <span class="email">Workbooks works without an account — sign in to use the network.</span>
      </div>
    {/if}
  </div>

  <div class="divider"></div>

  <div class="status-block">
    {#each rows as row (row.key)}
      <div class="status-row">
        <span class="dot dot-{row.dot}"></span>
        <span class="status-label">{row.key}</span>
        <span class="status-val">{row.label}</span>
      </div>
    {/each}
  </div>

  <div class="divider"></div>

  {#if auth.status === "signed-in"}
    <button type="button" class="item" role="menuitem" onclick={doSignOut} disabled={auth.busy}>
      <LogOut size={13} strokeWidth={2} /> Sign out
    </button>
  {:else if auth.status === "signed-out"}
    <button type="button" class="item" role="menuitem" onclick={doSignIn} disabled={auth.busy}>
      <LogIn size={13} strokeWidth={2} />
      {auth.busy ? "Opening sign-in…" : "Sign in to Workbooks"}
    </button>
    <button type="button" class="item subtle" role="menuitem" onclick={doReset} disabled={auth.resetting}>
      <RefreshCw size={13} strokeWidth={2} class={auth.resetting ? "spinning" : ""} />
      {auth.resetting ? "Resetting…" : "Reset local sign-in"}
    </button>
  {/if}

  {#if auth.engineState !== "ok" && auth.engineState !== "starting"}
    <button type="button" class="item" role="menuitem" onclick={doRestart} disabled={auth.busy}>
      <RefreshCw size={13} strokeWidth={2} class={auth.busy ? "spinning" : ""} />
      Restart engine
    </button>
  {/if}
</div>

<style>
  .menu {
    position: absolute;
    left: calc(100% + 6px);
    bottom: 0.85rem;
    min-width: 220px;
    padding: 8px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    box-shadow: 0 6px 22px rgba(15, 15, 15, 0.1);
    z-index: 200;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 8px 8px;
  }
  .avatar {
    flex-shrink: 0;
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    border-radius: 999px;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 0.7rem;
    font-weight: 600;
    object-fit: cover;
  }
  .avatar.lg {
    width: 30px;
    height: 30px;
    font-size: 0.84rem;
  }
  .avatar.muted {
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    border: 1px solid var(--color-border);
  }
  .meta {
    display: flex;
    flex-direction: column;
    min-width: 0;
    gap: 1px;
  }
  .name {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--color-fg);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .name.muted {
    color: var(--color-fg-muted);
    font-weight: 500;
  }
  .email {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .divider {
    height: 1px;
    background: var(--color-border);
    margin: 2px 0;
  }
  .status-block {
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 4px 0;
  }
  .status-row {
    display: grid;
    grid-template-columns: 8px 1fr auto;
    align-items: center;
    gap: 8px;
    padding: 4px 10px;
  }
  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--color-fg-muted);
  }
  .dot-ok {
    background: rgb(34, 160, 105);
  }
  .dot-pending {
    background: rgb(220, 165, 30);
    animation: pulse 1200ms ease-in-out infinite;
  }
  .dot-warn {
    background: rgb(220, 130, 30);
  }
  .dot-err {
    background: rgb(220, 60, 60);
  }
  .dot-idle {
    background: var(--color-fg-muted);
    opacity: 0.45;
  }
  .status-label {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    text-transform: uppercase;
    letter-spacing: 0.03em;
    font-weight: 600;
  }
  .status-val {
    font-size: 0.78rem;
    color: var(--color-fg);
    font-weight: 500;
    max-width: 130px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .item {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 7px 10px;
    border-radius: 6px;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.84rem;
    text-align: left;
    cursor: pointer;
  }
  .item:hover:not(:disabled) {
    background: var(--color-surface-soft);
  }
  .item.subtle {
    color: var(--color-fg-muted);
  }
  .item:disabled {
    opacity: 0.5;
    cursor: default;
  }
  @keyframes pulse {
    0%,
    100% {
      opacity: 0.55;
    }
    50% {
      opacity: 1;
    }
  }
  :global(.spinning) {
    animation: spin 900ms linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
