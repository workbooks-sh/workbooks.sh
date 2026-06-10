<script lang="ts">
  /**
   * ConnectModal — generic "paste your API key" dialog for the
   * connected-service cards on the Integrations tab.
   *
   * The user signs up at the third-party service themselves (we are
   * not the integration provider; we just bridge their account into
   * the agent). This modal:
   *
   *   1. Names the service we're about to connect.
   *   2. Links out to wherever the user gets their API key for the
   *      service (the "where do I find this?" affordance).
   *   3. Takes the API key and (optional) account label.
   *   4. Hands the values back via `onsubmit` — the parent calls the
   *      Rust `connections_create` command, which encrypts the key at
   *      rest and forwards the matching env var to the sidecar on
   *      next restart.
   *
   * The plaintext value lives in `$state` only for the duration of
   * the modal; on submit/cancel it's discarded.
   */
  import { Check, ArrowSquareOut as ExternalLink } from "phosphor-svelte";

  let {
    serviceName,
    serviceLogo,
    apiKeyHint,
    getKeyUrl,
    busy = false,
    error = null,
    onsubmit,
    oncancel,
  }: {
    /** Display name — "Composio", "Doppler", "GitHub". */
    serviceName: string;
    /** Inline SVG markup (brand mark) shown in the modal header. */
    serviceLogo: string;
    /** Short hint shown above the input — e.g. "sk-..." or "ck_...". */
    apiKeyHint?: string;
    /** Where the user gets their API key from the service. */
    getKeyUrl: string;
    busy?: boolean;
    error?: string | null;
    onsubmit: (req: { apiKey: string; accountLabel: string | null }) => void;
    oncancel: () => void;
  } = $props();

  let apiKey = $state("");
  let accountLabel = $state("");
  let cardEl: HTMLDivElement | undefined = $state();

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    oncancel();
  }

  function key(e: KeyboardEvent) {
    if (e.key === "Escape") oncancel();
  }

  function submit() {
    const k = apiKey.trim();
    if (!k) return;
    const label = accountLabel.trim();
    onsubmit({ apiKey: k, accountLabel: label.length > 0 ? label : null });
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
          Paste your personal {serviceName} API key. We store it
          encrypted on this machine and forward it to the agent.
        </p>
      </div>
    </header>

    <form onsubmit={(e) => { e.preventDefault(); submit(); }}>
      <label>
        <span class="label-row">
          <span>API key</span>
          <a
            href={getKeyUrl}
            target="_blank"
            rel="noopener noreferrer"
            class="get-key"
          >
            Get one here <ExternalLink weight="fill" size={11} />
          </a>
        </span>
        <input
          type="password"
          bind:value={apiKey}
          placeholder={apiKeyHint ?? "Paste your API key"}
          autocomplete="off"
          spellcheck="false"
          autofocus
          disabled={busy}
        />
      </label>

      <label>
        <span class="label-row">
          <span>Label <span class="optional">(optional)</span></span>
        </span>
        <input
          type="text"
          bind:value={accountLabel}
          placeholder="personal, work, …"
          autocomplete="off"
          disabled={busy}
        />
      </label>

      <div class="row">
        <button
          type="button"
          class="btn ghost"
          disabled={busy}
          onclick={oncancel}
        >
          Cancel
        </button>
        <button
          type="submit"
          class="btn primary"
          disabled={busy || !apiKey.trim()}
        >
          <Check weight="bold" size={13} />
          {busy ? "Connecting…" : "Connect"}
        </button>
      </div>
    </form>

    {#if error}<div class="err">{error}</div>{/if}
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
    max-width: 420px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.25rem 1.25rem 1rem;
  }
  .head {
    display: flex;
    gap: 0.7rem;
    align-items: flex-start;
    margin-bottom: 1rem;
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
  form { display: flex; flex-direction: column; gap: 0.7rem; }
  label {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .label-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 0.74rem;
    color: var(--color-fg-muted);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-weight: 600;
  }
  .optional {
    text-transform: none;
    font-weight: 400;
    letter-spacing: 0;
    color: var(--color-fg-subtle);
  }
  .get-key {
    display: inline-flex;
    align-items: center;
    gap: 0.2rem;
    color: var(--color-fg-muted);
    text-decoration: none;
    text-transform: none;
    letter-spacing: 0;
    font-weight: 500;
    font-size: 0.72rem;
  }
  .get-key:hover { color: var(--color-fg); }
  input {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    padding: 0.5rem 0.65rem;
    font-size: 0.88rem;
    font-family: inherit;
    color: var(--color-fg);
    outline: 0;
  }
  input:focus { border-color: var(--color-border-strong); }
  .row {
    display: flex;
    gap: 0.4rem;
    justify-content: flex-end;
    margin-top: 0.4rem;
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
  .err {
    margin-top: 0.65rem;
    font-size: 0.76rem;
    color: #ef4444;
    word-break: break-word;
  }
</style>
