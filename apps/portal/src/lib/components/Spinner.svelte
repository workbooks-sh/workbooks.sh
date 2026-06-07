<script lang="ts">
  interface Props {
    size?: number;
  }
  let { size = 14 }: Props = $props();
</script>

<span class="spinner" style="width:{size}px;height:{size}px;" aria-label="loading">
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
    <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
  </svg>
</span>

<style>
  .spinner {
    display: inline-block;
    color: var(--color-fg-muted);
    animation: spin 1s linear infinite;
    flex-shrink: 0;
  }

  .spinner svg {
    width: 100%;
    height: 100%;
  }

  @keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }
</style>
