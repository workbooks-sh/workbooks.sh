<script lang="ts">
  /**
   * ModifiedWarningBanner — wb-u2o0.5.3.
   *
   * Prominent full-width strip surfaced when a workbook's bytes don't
   * match the publisher's signed snapshot. Tampered bytes
   * (or even benign re-exports that drop the manifest) are a real
   * safety concern, so we want this LOUDER than the inline
   * ProvenanceBadge "modified" pill.
   *
   * Two affordances:
   *   - "Fetch authoritative" — pulls the canonical bytes via the
   *     RID over Radicle. Workhorse handles the actual sync. v1 wires
   *     a stub callback; the real Radicle-pull path is a Workhorse
   *     IPC follow-up.
   *   - Dismiss — collapses the banner. Persists per-RID-per-session
   *     (caller responsibility — we just emit the event).
   */
  import { ShieldAlert, RefreshCw, X } from "@lucide/svelte";

  let {
    by = null,
    rid = null,
    onfetchauthoritative = () => {},
    ondismiss = () => {},
    fetching = false,
  }: {
    by?: string | null;
    rid?: string | null;
    onfetchauthoritative?: () => void;
    ondismiss?: () => void;
    fetching?: boolean;
  } = $props();
</script>

<div class="banner" role="alert" aria-live="polite">
  <ShieldAlert size={16} strokeWidth={2.25} class="icon" />
  <div class="body">
    <div class="title">
      This file's bytes don't match what {by ? `@${by}` : "the publisher"} signed.
    </div>
    <div class="sub">
      The workbook was modified after publication. Workhorse can fetch the
      original via Radicle so you see what the publisher actually signed.
    </div>
  </div>
  <div class="actions">
    <button
      type="button"
      class="btn primary"
      onclick={onfetchauthoritative}
      disabled={fetching || !rid}
      title={!rid ? "No RID available — can't pull authoritative copy" : ""}
    >
      <RefreshCw size={12} strokeWidth={2.25} class={fetching ? "spinning" : ""} />
      {fetching ? "Fetching…" : "Fetch authoritative"}
    </button>
    <button type="button" class="btn ghost" onclick={ondismiss} aria-label="Dismiss warning">
      <X size={13} strokeWidth={2.25} />
    </button>
  </div>
</div>

<style>
  .banner {
    display: flex;
    align-items: flex-start;
    gap: 11px;
    padding: 11px 14px 11px 12px;
    background: linear-gradient(180deg, rgba(225, 145, 30, 0.13), rgba(225, 145, 30, 0.07));
    border: 1px solid rgba(225, 145, 30, 0.36);
    border-radius: 8px;
    color: rgb(120, 75, 8);
  }
  .banner :global(.icon) {
    flex: 0 0 auto;
    margin-top: 1px;
  }
  .body { flex: 1; min-width: 0; }
  .title {
    font-size: 0.78rem;
    font-weight: 600;
    line-height: 1.35;
  }
  .sub {
    margin-top: 3px;
    font-size: 0.72rem;
    line-height: 1.45;
    color: rgb(150, 95, 10);
  }
  .actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 10px;
    border-radius: 6px;
    font-size: 0.72rem;
    font-weight: 600;
    line-height: 1;
    border: 1px solid transparent;
    cursor: pointer;
    transition: background 120ms ease;
  }
  .btn.primary {
    color: white;
    background: rgb(184, 110, 20);
    border-color: rgba(150, 90, 15, 0.6);
  }
  .btn.primary:hover:not(:disabled) {
    background: rgb(155, 90, 12);
  }
  .btn.primary:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }
  .btn.ghost {
    background: transparent;
    color: rgb(150, 95, 10);
    padding: 5px 6px;
  }
  .btn.ghost:hover {
    background: rgba(225, 145, 30, 0.12);
  }
  :global(.spinning) {
    animation: spin 900ms linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  @media (prefers-color-scheme: dark) {
    .banner {
      background: linear-gradient(180deg, rgba(225, 145, 30, 0.18), rgba(225, 145, 30, 0.10));
      border-color: rgba(225, 145, 30, 0.45);
      color: rgb(245, 195, 110);
    }
    .sub { color: rgb(220, 175, 105); }
    .btn.ghost { color: rgb(245, 195, 110); }
  }
</style>
