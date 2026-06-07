<script lang="ts">
  /**
   * Workgate approval modal (wb-80q0.10).
   *
   * Renders when the workgate store has a pending request. One-modal-
   * at-a-time by construction — the store advances only after the
   * user clicks Allow or Deny.
   *
   * The modal is the entire safety mitigation for `os.*` capabilities.
   * Every time the agent asks for camera / mic / screen / real-FS-
   * outside-monorepo / launch-app, the user sees a prompt here with:
   *   - the capability name (verbatim — no marketing copy)
   *   - the agent's stated reason
   *   - the scope shape (verbatim — the user sees exactly what was
   *     requested)
   *   - Allow / Deny buttons + a remember dropdown
   *
   * Per docs/desktop/agent-sandbox.md §5.4 the chrome must be
   * consistent across prompts so users build a mental model. This
   * component is the one place that chrome lives.
   */
  import { workgate, type RememberKind } from "./store.svelte";

  let remember = $state<RememberKind>("one_time");
  let acting = $state(false);

  // Show the modal only when there's a pending request.
  const req = $derived(workgate.current);

  async function onAllow() {
    if (!req || acting) return;
    acting = true;
    try {
      await workgate.allow({ remember });
    } finally {
      acting = false;
      remember = "one_time";
    }
  }

  async function onDeny() {
    if (!req || acting) return;
    acting = true;
    try {
      await workgate.deny();
    } finally {
      acting = false;
      remember = "one_time";
    }
  }
</script>

{#if req}
  <div class="overlay" data-testid="workgate-overlay">
    <div class="modal" role="dialog" aria-modal="true" aria-labelledby="wg-title">
      <header>
        <span class="badge">Workgate</span>
        <h2 id="wg-title">{req.capability}</h2>
      </header>

      <p class="reason">{req.reason}</p>

      {#if Object.keys(req.scope).length > 0}
        <div class="scope">
          <div class="scope-label">Scope</div>
          <pre>{JSON.stringify(req.scope, null, 2)}</pre>
        </div>
      {/if}

      <div class="meta">
        {#if req.workspace}
          <span>workspace: <code>{req.workspace}</code></span>
        {/if}
        {#if req.session}
          <span>session: <code>{req.session}</code></span>
        {/if}
        <span>id: <code>{req.id}</code></span>
      </div>

      <div class="remember">
        <label for="wg-remember">Remember</label>
        <select id="wg-remember" bind:value={remember} disabled={acting}>
          <option value="one_time">Just this once</option>
          <option value="this_session">For this session</option>
          <option value="this_workspace">For this workspace</option>
        </select>
      </div>

      <div class="actions">
        <button class="btn deny" onclick={onDeny} disabled={acting} data-testid="workgate-deny">
          Deny
        </button>
        <button class="btn allow" onclick={onAllow} disabled={acting} data-testid="workgate-allow">
          Allow
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.45);
    z-index: 9999;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
  }

  .modal {
    background: var(--color-surface, #fff);
    color: var(--color-fg, #111);
    border: 1px solid var(--color-border, #ddd);
    border-radius: 12px;
    box-shadow: 0 24px 48px rgba(0, 0, 0, 0.18);
    padding: 1.25rem 1.25rem 1rem;
    width: 100%;
    max-width: 440px;
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
  }

  header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .badge {
    background: var(--color-fg, #111);
    color: var(--color-page, #fff);
    font-size: 0.65rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 0.15rem 0.45rem;
    border-radius: 999px;
  }

  h2 {
    margin: 0;
    font-size: 1.05rem;
    font-weight: 600;
    letter-spacing: -0.015em;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }

  .reason {
    margin: 0;
    font-size: 0.9rem;
    line-height: 1.45;
    color: var(--color-fg, #111);
  }

  .scope {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .scope-label {
    font-size: 0.7rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-fg-muted, #555);
  }
  .scope pre {
    margin: 0;
    background: var(--color-surface-soft, #f5f5f5);
    border: 1px solid var(--color-border, #e0e0e0);
    border-radius: 6px;
    padding: 0.5rem 0.6rem;
    font-size: 0.78rem;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    overflow-x: auto;
  }

  .meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem 0.9rem;
    font-size: 0.7rem;
    color: var(--color-fg-muted, #777);
  }
  .meta code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }

  .remember {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .remember label {
    font-size: 0.7rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-fg-muted, #555);
  }
  .remember select {
    padding: 0.4rem 0.5rem;
    border: 1px solid var(--color-border, #ddd);
    border-radius: 6px;
    background: var(--color-surface-soft, #f5f5f5);
    color: var(--color-fg, #111);
    font-size: 0.85rem;
    font-family: inherit;
  }

  .actions {
    display: flex;
    gap: 0.5rem;
    justify-content: flex-end;
    margin-top: 0.25rem;
  }
  .btn {
    height: 34px;
    padding: 0 0.85rem;
    border-radius: 7px;
    font-size: 0.85rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    border: 1px solid var(--color-border, #ddd);
    background: var(--color-surface-soft, #f5f5f5);
    color: var(--color-fg, #111);
    transition: opacity 0.12s, background 0.12s;
  }
  .btn:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .btn.allow {
    background: var(--color-fg, #111);
    color: var(--color-page, #fff);
    border-color: var(--color-fg, #111);
  }
  .btn.deny:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.12);
    border-color: rgba(239, 68, 68, 0.4);
  }
</style>
