<script lang="ts">
  /**
   * ToastStack (wb-i38o.13) — bottom-right toast viewer mounted once
   * from +page.svelte. Reads from the `toasts` store; each toast shows
   * a kind-coloured chip + dismiss button (errors are sticky until
   * dismissed, progress stays until the originator calls .update() to
   * upgrade it to success/error).
   *
   * Semantic-colour rule from CLAUDE.md:
   *   progress = amber, success = emerald, error = rose
   */
  import { CircleCheck, CircleAlert, Loader, X } from "@lucide/svelte";
  import { toasts, type Toast } from "$lib/bridge/toasts.svelte";

  function dismiss(id: number) {
    toasts.dismiss(id);
  }

  function iconFor(kind: Toast["kind"]) {
    switch (kind) {
      case "success":
        return CircleCheck;
      case "error":
        return CircleAlert;
      case "progress":
        return Loader;
      default:
        return CircleCheck;
    }
  }
</script>

<div class="stack" aria-live="polite" aria-atomic="false">
  {#each toasts.items as toast (toast.id)}
    {@const Icon = iconFor(toast.kind)}
    <div class="toast toast-{toast.kind}" role="status">
      <span class="icon" class:spin={toast.kind === "progress"}>
        <Icon size={14} strokeWidth={1.8} />
      </span>
      <span class="msg">{toast.message}</span>
      <button
        class="dismiss"
        aria-label="Dismiss"
        title="Dismiss"
        onclick={() => dismiss(toast.id)}
      >
        <X size={12} strokeWidth={1.8} />
      </button>
    </div>
  {/each}
</div>

<style>
  .stack {
    position: fixed;
    right: 16px;
    bottom: 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    z-index: 2000;
    pointer-events: none;
  }
  .toast {
    pointer-events: auto;
    display: flex;
    align-items: center;
    gap: 0.55rem;
    min-width: 260px;
    max-width: 480px;
    padding: 8px 10px 8px 12px;
    border-radius: 8px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    box-shadow:
      0 4px 6px rgba(0, 0, 0, 0.06),
      0 12px 28px rgba(0, 0, 0, 0.14);
    font-size: 12.5px;
    color: var(--color-fg);
    line-height: 1.45;
  }
  .toast-progress {
    border-left: 3px solid #f59e0b;
  }
  .toast-success {
    border-left: 3px solid #10b981;
  }
  .toast-error {
    border-left: 3px solid #f43f5e;
  }
  .toast-info {
    border-left: 3px solid var(--color-border);
  }
  .icon {
    display: inline-flex;
    flex-shrink: 0;
    color: var(--color-fg-muted);
  }
  .toast-progress .icon { color: #f59e0b; }
  .toast-success .icon  { color: #10b981; }
  .toast-error .icon    { color: #f43f5e; }
  .msg {
    flex: 1;
    word-break: break-word;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    font-size: 12px;
  }
  .dismiss {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border: 0;
    background: transparent;
    color: var(--color-fg-subtle);
    border-radius: 4px;
    cursor: pointer;
  }
  .dismiss:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .spin :global(svg) {
    animation: toast-spin 1s linear infinite;
  }
  @keyframes toast-spin {
    to { transform: rotate(360deg); }
  }
</style>
