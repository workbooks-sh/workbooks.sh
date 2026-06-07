<script lang="ts">
  /**
   * Env-request approval modal — desktop surface for `wb env request`.
   *
   * Renders when the env-request store has a pending request. One
   * modal at a time, by construction: the store advances only after
   * the user clicks Provide or Cancel.
   *
   * The agent never sees the value the user types — it goes directly
   * from this modal to the engine over the `engine:env_prompt`
   * channel as the `env:fulfill` event, which writes to the
   * workspace's dedicated keychain. The original `wb env request`
   * call returns with `status: "fulfilled"` once the write lands.
   *
   * Mirror of WorkgateModal — same chrome conventions per docs/
   * desktop/agent-sandbox.md §5.4 so users build one mental model
   * for "agent is asking the desktop for something."
   */
  import { envRequests } from "./store.svelte";

  let value = $state("");
  let locked = $state(true);
  let acting = $state(false);
  let saved = $state<{ name: string; workspace: string } | null>(null);

  const req = $derived(envRequests.current);

  // When the request changes (queue advanced), reset the form.
  $effect(() => {
    if (req) {
      value = "";
      locked = req.locked;
      saved = null;
    }
  });

  async function onProvide() {
    if (!req || acting) return;
    if (value.length === 0) return;
    acting = true;
    const stash = { name: req.name, workspace: req.workspace };
    try {
      await envRequests.fulfill(value, locked);
      saved = stash;
      value = "";
      // Brief confirmation; auto-clear after a tick.
      setTimeout(() => {
        saved = null;
      }, 1200);
    } finally {
      acting = false;
    }
  }

  async function onCancel() {
    if (!req || acting) return;
    acting = true;
    try {
      await envRequests.cancel();
      value = "";
    } finally {
      acting = false;
    }
  }
</script>

{#if req}
  <div class="overlay" data-testid="env-request-overlay">
    <div class="modal" role="dialog" aria-modal="true" aria-labelledby="env-title">
      <header>
        <span class="badge">Env</span>
        <h2 id="env-title">Agent needs an environment variable</h2>
      </header>

      <div class="row">
        <div class="label">Name</div>
        <code class="value mono">{req.name}</code>
      </div>

      <div class="row">
        <div class="label">Workspace</div>
        <code class="value mono">{req.workspace}</code>
      </div>

      {#if req.reason}
        <p class="reason">{req.reason}</p>
      {/if}

      {#if req.hint}
        <div class="row">
          <div class="label">Hint</div>
          <code class="value mono">{req.hint}</code>
        </div>
      {/if}

      <div class="field">
        <label for="env-value">Value</label>
        <input
          id="env-value"
          type="password"
          autocomplete="off"
          spellcheck="false"
          bind:value
          disabled={acting}
          data-testid="env-request-value"
          placeholder={req.hint ?? "Paste the value here"}
        />
      </div>

      <div class="field row-inline">
        <input
          id="env-locked"
          type="checkbox"
          bind:checked={locked}
          disabled={acting}
        />
        <label for="env-locked">Store as locked (redact in <code>wb env get</code>)</label>
      </div>

      {#if saved}
        <div class="saved">Saved to workspace <code>{saved.workspace}</code></div>
      {/if}

      <div class="meta">
        <span>id: <code>{req.id}</code></span>
      </div>

      <div class="actions">
        <button
          class="btn cancel"
          onclick={onCancel}
          disabled={acting}
          data-testid="env-request-cancel"
        >
          Cancel
        </button>
        <button
          class="btn provide"
          onclick={onProvide}
          disabled={acting || value.length === 0}
          data-testid="env-request-provide"
        >
          Provide
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
    max-width: 460px;
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
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
    font-size: 1rem;
    font-weight: 600;
    letter-spacing: -0.015em;
  }

  .row {
    display: flex;
    align-items: baseline;
    gap: 0.5rem;
  }
  .row-inline {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .label {
    font-size: 0.7rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-fg-muted, #555);
    min-width: 70px;
  }

  .value,
  code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 0.82rem;
  }
  .mono {
    background: var(--color-surface-soft, #f5f5f5);
    border: 1px solid var(--color-border, #e0e0e0);
    border-radius: 4px;
    padding: 0.1rem 0.35rem;
  }

  .reason {
    margin: 0;
    font-size: 0.9rem;
    line-height: 1.4;
    color: var(--color-fg, #111);
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .field label {
    font-size: 0.7rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-fg-muted, #555);
  }
  .field input[type="password"] {
    padding: 0.45rem 0.55rem;
    border: 1px solid var(--color-border, #ddd);
    border-radius: 6px;
    background: var(--color-surface-soft, #f5f5f5);
    color: var(--color-fg, #111);
    font-size: 0.85rem;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }
  .field input[type="checkbox"] {
    width: 14px;
    height: 14px;
  }
  .row-inline label {
    font-size: 0.78rem;
    text-transform: none;
    letter-spacing: 0;
    color: var(--color-fg, #111);
    font-weight: 400;
  }

  .saved {
    font-size: 0.8rem;
    color: rgb(16, 185, 129);
  }

  .meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem 0.9rem;
    font-size: 0.7rem;
    color: var(--color-fg-muted, #777);
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
  .btn.provide {
    background: var(--color-fg, #111);
    color: var(--color-page, #fff);
    border-color: var(--color-fg, #111);
  }
  .btn.cancel:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.12);
    border-color: rgba(239, 68, 68, 0.4);
  }
</style>
