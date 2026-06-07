<script lang="ts">
  /**
   * Modal — backdrop + centered card dialog. Esc and backdrop-click
   * call `onclose`. Optional `title`/`lede` header and a `footer`
   * snippet (the action row, right-aligned). `children` is the body.
   * Width follows `size` (sm 380 / md 480). Pop-in on mount.
   */
  import type { Snippet } from "svelte";

  let {
    open = false,
    title,
    lede,
    size = "sm",
    onclose,
    children,
    footer,
  }: {
    open?: boolean;
    title?: string;
    lede?: string;
    size?: "sm" | "md";
    onclose?: () => void;
    children?: Snippet;
    footer?: Snippet;
  } = $props();

  $effect(() => {
    if (!open) return;
    function key(e: KeyboardEvent) {
      if (e.key === "Escape") {
        e.preventDefault();
        onclose?.();
      }
    }
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  });
</script>

{#if open}
  <div
    class="backdrop"
    role="presentation"
    onclick={(e) => e.target === e.currentTarget && onclose?.()}
  >
    <div class="card {size}" role="dialog" aria-modal="true">
      {#if title}
        <header>
          <h3>{title}</h3>
          {#if lede}<p>{lede}</p>{/if}
        </header>
      {/if}
      {#if children}<div class="body">{@render children()}</div>{/if}
      {#if footer}<div class="footer">{@render footer()}</div>{/if}
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
    background: rgba(0, 0, 0, 0.28);
  }
  .card {
    width: 100%;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.5rem;
    animation: pop-in 0.1s ease-out;
  }
  .card.sm { max-width: 380px; }
  .card.md { max-width: 480px; }
  @keyframes pop-in {
    from { opacity: 0; transform: translateY(-3px); }
    to { opacity: 1; transform: translateY(0); }
  }
  header { margin-bottom: 1rem; }
  h3 {
    margin: 0;
    font-size: 0.98rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    color: var(--color-fg);
  }
  p {
    margin: 0.25rem 0 0;
    font-size: 0.8rem;
    line-height: 1.45;
    color: var(--color-fg-muted);
  }
  .body { display: flex; flex-direction: column; gap: 0.7rem; }
  .footer {
    display: flex;
    justify-content: flex-end;
    gap: 0.4rem;
    margin-top: 1.25rem;
  }
</style>
